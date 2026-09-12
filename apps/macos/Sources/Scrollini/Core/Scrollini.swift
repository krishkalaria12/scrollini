import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

final class Scrollini: NSObject, NSMenuDelegate, @unchecked Sendable {
    enum LayoutSnapshotTiming {
        case immediate
        case deferred
    }

    struct TrackpadNavigationSettings: Equatable {
        var enabled: Bool
        var workspaceFingers: Int
        var invertY: Bool
        var directionLockThreshold: CGFloat
    }

    struct TransientSystemWindow {
        var element: AXUIElement
        var recoverable: Bool
    }

    /// A rule's key exclusions, normalized once at config load so the event tap does no string
    /// parsing per keystroke.
    struct AppKeybindingExclusion {
        var bundleID: String?
        var appName: String?
        var chords: Set<String>

        func matches(bundleID candidateBundleID: String?, appName candidateAppName: String?) -> Bool {
            if let bundleID, bundleID != candidateBundleID {
                return false
            }
            if let appName, appName != candidateAppName {
                return false
            }
            return true
        }
    }

    var loadedConfig = ScrolliniConfig.loadWithMetadata()
    /// When no config file has ever loaded, every rescan tick retries the candidate paths. Parse
    /// failures there must not be logged each time, so complaints are suppressed until a load
    /// actually succeeds. Starts suppressed because the load above has already had its say.
    var configLoadErrorsSuppressed = true
    var config: ScrolliniConfig {
        loadedConfig.config
    }
    var workspaces: [Workspace] = [Workspace()]
    var floatingWindows: [ManagedWindow] = []
    var activeWorkspace: Int = 0
    weak var previousWorkspace: Workspace?
    var observers: [pid_t: AXObserver] = [:]
    var eventTap: CFMachPort?
    var eventTapSource: CFRunLoopSource?
    var swallowedKeyUps = Set<Int64>()
    var commandByKeybinding: [String: Command] = [:]
    var globalHotkeys: [GlobalHotkey] = []
    var globalHotkeyBindings = Set<String>()
    var globalHotkeyHandler: EventHandlerRef?
    var excludedKeybindingSet = Set<String>()
    var appKeybindingExclusions: [AppKeybindingExclusion] = []
    /// Frontmost app identity, cached from workspace activation notifications. Reading
    /// `NSWorkspace.shared.frontmostApplication` on the event tap thread for every key down would
    /// put a cross-process lookup in the hot path.
    var frontmostAppBundleID: String?
    var frontmostAppName: String?
    var keybindingsPaused = false
    var scheduledRescanTimer: DispatchSourceTimer?
    var scheduledRescanAdoptFocused = false
    var scheduledRescanProjectLayout = false
    var pendingColumnNavigationDelta = 0
    var pendingColumnNavigationTimer: DispatchSourceTimer?
    var pendingColumnNavigationStartedAt: CFAbsoluteTime = 0
    var pendingColumnNavigationProjectionState: LayoutState?
    var columnNavigationFocusTimer: DispatchSourceTimer?
    var columnNavigationFocusGeneration: UInt64 = 0
    var lastColumnNavigationAt: CFAbsoluteTime = 0
    var lastColumnNavigationDirection = 0
    var rescanTimer: Timer?
    var isApplyingLayout = false
    var layoutLockGeneration: UInt64 = 0
    var animationTimer: DispatchSourceTimer?
    var animationGeneration: UInt64 = 0
    var focusedWindowAdoptionSuppressedUntil: CFAbsoluteTime = 0
    var expectedFocusedWindow: ObjectIdentifier?
    var expectedFocusedWindowUntil: CFAbsoluteTime = 0
    var focusRequestGeneration: UInt64 = 0
    var focusVerificationGeneration: UInt64 = 0
    var layoutVerificationGeneration: UInt64 = 0
    var columnMeasurementGeneration: UInt64 = 0
    var hoverFocusTimer: DispatchSourceTimer?
    var hoverFocusTarget: ObjectIdentifier?
    var hoverFocusRequiresRearm = false
    var hoverFocusSuppressedUntil: CFAbsoluteTime = 0
    var transientWindowActive = false
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var trackpadNavigation: ThreeFingerTrackpadNavigation?
    var trackpadCameraY: CGFloat?
    var trackpadCameraVelocity: CGFloat = 0
    var trackpadPendingCameraDelta: CGFloat = 0
    var trackpadLatestCameraVelocity: CGFloat = 0
    var trackpadRenderTimer: DispatchSourceTimer?
    var trackpadMomentumTimer: DispatchSourceTimer?
    var trackpadMomentumLastFrameAt: CFAbsoluteTime = 0
    var manualResizeEndTimer: DispatchSourceTimer?
    var manualResizeElement: AXUIElement?
    var manualResizeSuppressedUntil: CFAbsoluteTime = 0
    var cachedViewport: CGRect?
    var cachedViewportAt: CFAbsoluteTime = 0
    /// Short enough that a menu bar or Dock change nobody told us about self-heals within a
    /// frame or two, long enough that a single layout pass never reads two different viewports.
    let viewportCacheDuration: CFAbsoluteTime = 0.2
    var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    var appliedAlphas: [UInt32: Float] = [:]
    var appliedWindowLevels: [UInt32: Int32] = [:]
    var snapshotWriteTimer: DispatchSourceTimer?
    var pendingSnapshotViewport: CGRect?
    var lastPersistentLayoutSnapshotData: Data?
    var lastRestoreSnapshotData: Data?
    var floatingRaiseGeneration: UInt64 = 0
    lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    var needsPersistentLayoutRestore = true
    var needsPersistentFocusRestore = true
    /// Restoring a saved layout is a startup step, not a standing rule. Apps that were open last
    /// session take a few seconds to come back, so the snapshot stays live for a short grace
    /// period and is then dropped: past that, a window whose app and title happen to match is a
    /// coincidence, and rearranging every workspace around it is worse than leaving it alone.
    let persistentLayoutRestoreDeadline = CFAbsoluteTimeGetCurrent() + 20
    var signalSources: [DispatchSourceSignal] = []
    let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scrollini-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    var cleanupWatcher: Process?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    let normalWindowLevel = Int32(CGWindowLevelForKey(.normalWindow))
    let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    let frameTimerInterval: DispatchTimeInterval = .milliseconds(16)
    let frameTimerLeeway: DispatchTimeInterval = .milliseconds(1)

    func start() {
        guard requestAccessibilityPermission() else {
            fputs("scrollini: Accessibility permission is required. Enable it for this binary or Terminal, then run again.\n", stderr)
            exit(1)
        }

        boundAccessibilityMessagingTimeout()
        observeWorkspace()
        installTerminationHandlers()
        if restoreOnExit {
            startCleanupWatcher()
        }
        configureInput()
        installEventTap()
        installTrackpadNavigation()
        installStatusItem()
        rescanWindows(adoptFocused: true)
        scheduleRescanTimer()

        print("scrollini: running")
        print("scrollini: loaded \(commandByKeybinding.count) keybindings")
        if !appKeybindingExclusions.isEmpty {
            print("scrollini: \(appKeybindingExclusions.count) app rule(s) reserve keybindings for themselves")
        }
        if trackpadNavigationEnabled {
            if trackpadNavigation != nil {
                print("scrollini: \(trackpadNavigationWorkspaceFingers)-finger swipe up/down changes workspaces")
            } else {
                print("scrollini: trackpad navigation unavailable; private MultitouchSupport backend did not start")
            }
        }
        print("scrollini: Cmd-Tab is passed through and adopted after macOS focuses a window")
        if hideMethod == .skyLightAlpha && !SkyLight.shared.canSetAlpha {
            print("scrollini: SkyLight alpha support unavailable; parked windows will remain as edge slivers")
        }
        runMainLoop()
    }

    func debugLog(_ message: String) {
        guard debugLogging else {
            return
        }
        print("scrollini: \(message)")
    }
}
