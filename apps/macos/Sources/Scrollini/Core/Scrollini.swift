import AppKit
import ApplicationServices
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
        var fingers: Int
        var invertX: Bool
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
    var excludedKeybindingSet = Set<String>()
    var appKeybindingExclusions: [AppKeybindingExclusion] = []
    /// Bumped whenever the rules change, which retires every per-window answer cached against
    /// them. Starts at 1 so a window's zero-valued default revision can never be mistaken for a
    /// live one.
    var windowRuleRevision: UInt64 = 1
    /// Frontmost app identity, cached from workspace activation notifications. Reading
    /// `NSWorkspace.shared.frontmostApplication` on the event tap thread for every key down would
    /// put a cross-process lookup in the hot path.
    var frontmostAppBundleID: String?
    var frontmostAppName: String?
    var frontmostApplication: NSRunningApplication?
    /// `NSWorkspace.shared.runningApplications` builds a fresh array of proxy objects on every
    /// access, and three hot paths ask for it: window discovery, the transient-dialog check
    /// behind every keystroke, and the open/save panel lookup inside that check. Launches and
    /// terminations both arrive as notifications, so the snapshot is refreshed from those rather
    /// than rebuilt per call. The age check is a backstop for whatever the notifications miss,
    /// not the primary mechanism.
    var cachedRunningApplications: [NSRunningApplication] = []
    var cachedRunningApplicationsAt: CFAbsoluteTime = 0
    let runningApplicationsCacheDuration: CFAbsoluteTime = 2
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
    /// What the window server reported the last time the periodic tick looked, and when a real
    /// accessibility sweep last ran. Together these let the tick skip the sweep when nothing has
    /// opened, closed, or been minimized.
    var lastWindowServerSignature: [UInt64] = []
    var lastFullRescanAt: CFAbsoluteTime = 0
    /// How long the tick may go on the window server's word alone. A window that is renamed while
    /// nothing else happens is invisible to the fingerprint, and window rules can match on title,
    /// so a real sweep still has to come round.
    let fullRescanInterval: CFAbsoluteTime = 5
    /// Elements that failed the manageability test on a check that can never change its mind.
    var unmanageableWindows: Set<AXElementKey> = []
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
    var lastHoverFocusPoint = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    var transientWindowActive = false
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var trackpadNavigation: ThreeFingerTrackpadNavigation?
    var trackpadCameraY: CGFloat?
    /// Axis the in-flight three-finger swipe committed to, so the settle only lands that axis.
    var trackpadCameraAxis: TrackpadNavigationAxis?
    var trackpadCameraVelocity = CGPoint.zero
    var trackpadPendingCameraDelta = CGSize.zero
    var trackpadLatestCameraVelocity = CGPoint.zero
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
    var lastFloatingRaiseAt: CFAbsoluteTime = 0
    /// Long enough that a scroll does not raise on every frame, short enough that a floating
    /// window a tiled one just slid under comes back to the front within a frame or two.
    let floatingRaiseInterval: CFAbsoluteTime = 0.1
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
                print("scrollini: three-finger trackpad swipe navigates columns/workspaces")
            } else {
                print("scrollini: three-finger trackpad navigation unavailable; private MultitouchSupport backend did not start")
            }
        }
        print("scrollini: Cmd-Tab is passed through and adopted after macOS focuses a window")
        if hideMethod == .skyLightAlpha && !SkyLight.shared.canSetAlpha {
            print("scrollini: SkyLight alpha support unavailable; parked windows will remain as edge slivers")
        }
        runMainLoop()
    }

    /// The message is an autoclosure so a disabled log costs one boolean read. Several call
    /// sites sit inside per-frame layout passes and interpolate counts that are themselves
    /// derived from walking every managed window, which an eager argument would compute sixty
    /// times a second whether or not anyone was listening.
    func debugLog(_ message: @autoclosure () -> String) {
        guard debugLogging else {
            return
        }
        print("scrollini: \(message())")
    }
}
