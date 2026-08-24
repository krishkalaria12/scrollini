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

    var loadedConfig = ScrolliniConfig.loadWithMetadata()
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

    func debugLog(_ message: String) {
        guard debugLogging else {
            return
        }
        print("scrollini: \(message)")
    }
}
