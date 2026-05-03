import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class Scrollini: NSObject, @unchecked Sendable {
    private let config = ScrolliniConfig.load()
    private var workspaces: [Workspace] = [Workspace()]
    private var floatingWindows: [ManagedWindow] = []
    private var activeWorkspace: Int = 0
    private weak var previousWorkspace: Workspace?
    private var observers: [pid_t: AXObserver] = [:]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var rescanTimer: Timer?
    private var isApplyingLayout = false
    private var animationTimer: DispatchSourceTimer?
    private var hoverFocusTimer: DispatchSourceTimer?
    private var hoverFocusTarget: ObjectIdentifier?
    private var hoverFocusRequiresRearm = false
    private var hoverFocusSuppressedUntil: CFAbsoluteTime = 0
    private var trackpadNavigation: ThreeFingerTrackpadNavigation?
    private var trackpadCameraY: CGFloat?
    private var trackpadCameraVelocity = CGPoint.zero
    private var trackpadPendingCameraDelta = CGSize.zero
    private var trackpadLatestCameraVelocity = CGPoint.zero
    private var trackpadRenderTimer: DispatchSourceTimer?
    private var trackpadMomentumTimer: DispatchSourceTimer?
    private var trackpadMomentumLastFrameAt: CFAbsoluteTime = 0
    private var manualResizeEndTimer: DispatchSourceTimer?
    private var manualResizeElement: AXUIElement?
    private var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    private let parkedSliverWidth: CGFloat = 1
    private var signalSources: [DispatchSourceSignal] = []
    private let hoverFocusEdgeTriggerWidth: CGFloat = 8
    private let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scrollini-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    private var cleanupWatcher: Process?

    func start() {
        guard requestAccessibilityPermission() else {
            fputs("scrollini: Accessibility permission is required. Enable it for this binary or Terminal, then run again.\n", stderr)
            exit(1)
        }

        observeWorkspace()
        installTerminationHandlers()
        startCleanupWatcher()
        installEventTap()
        installTrackpadNavigation()
        rescanWindows(adoptFocused: true)
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rescanWindows(adoptFocused: false)
        }

        print("scrollini: running")
        print("scrollini: Cmd+1..9 focus workspace, Cmd+0 previous workspace, Cmd+J/K workspace down/up, Cmd+H/L column left/right")
        print("scrollini: Cmd+[/] or Cmd+Home/End focus first/last column")
        print("scrollini: Cmd+Shift+1..9 move column to workspace, Cmd+Shift+J/K move column down/up, Cmd+Shift+H/L move column left/right")
        print("scrollini: Cmd+Shift+[/] or Cmd+Shift+Home/End move column to first/last")
        print("scrollini: Cmd+Ctrl+H/L cycle width presets, Cmd+Ctrl+-/= nudge width by 0.1")
        print("scrollini: Cmd+Ctrl+Shift+H/L cycle width presets for all windows, Cmd+Ctrl+Shift+-/= nudge all widths")
        if trackpadNavigationEnabled {
            if trackpadNavigation != nil {
                print("scrollini: three-finger trackpad swipe navigates columns/workspaces")
            } else {
                print("scrollini: three-finger trackpad navigation unavailable; private MultitouchSupport backend did not start")
            }
        }
        print("scrollini: Cmd-Tab is passed through and adopted after macOS focuses a window")
        if !SkyLight.shared.canSetAlpha {
            print("scrollini: SkyLight alpha support unavailable; parked windows will remain as edge slivers")
        }
        RunLoop.main.run()
    }

    private func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreManagedWindowsForExit()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startCleanupWatcher() {
        guard let executableURL = currentExecutableURL() else {
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cleanup-watch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            restoreStateURL.path,
        ]

        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }

        do {
            try process.run()
            cleanupWatcher = process
        } catch {
            fputs("scrollini: failed to start cleanup watcher: \(error)\n", stderr)
        }
    }

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            fputs("scrollini: unable to create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
            exit(1)
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("scrollini: unable to create event tap run loop source.\n", stderr)
            exit(1)
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installTrackpadNavigation() {
        guard trackpadNavigationEnabled else {
            return
        }

        let navigation = ThreeFingerTrackpadNavigation(
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleTrackpadNavigationEvent(event)
            }
        }

        guard navigation.start() else { return }

        trackpadNavigation = navigation
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> Bool {
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        guard modifiers == .maskCommand
            || modifiers == [.maskCommand, .maskShift]
            || modifiers == [.maskCommand, .maskControl]
            || modifiers == [.maskCommand, .maskControl, .maskShift]
        else {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyText = keyboardText(from: event)
        guard !isExcludedKeybinding(modifiers: modifiers, keyCode: keyCode, keyText: keyText) else {
            return false
        }

        let command: Command?
        if modifiers == .maskCommand {
            switch keyCode {
            case KeyCode.one: command = .focusWorkspace(1)
            case KeyCode.two: command = .focusWorkspace(2)
            case KeyCode.three: command = .focusWorkspace(3)
            case KeyCode.four: command = .focusWorkspace(4)
            case KeyCode.five: command = .focusWorkspace(5)
            case KeyCode.six: command = .focusWorkspace(6)
            case KeyCode.seven: command = .focusWorkspace(7)
            case KeyCode.eight: command = .focusWorkspace(8)
            case KeyCode.nine: command = .focusWorkspace(9)
            case KeyCode.zero: command = .focusPreviousWorkspace
            case KeyCode.h: command = .columnLeft
            case KeyCode.j: command = .workspaceDown
            case KeyCode.k: command = .workspaceUp
            case KeyCode.l: command = .columnRight
            case KeyCode.leftBracket, KeyCode.home: command = .columnFirst
            case KeyCode.rightBracket, KeyCode.end: command = .columnLast
            case _ where keyText == "{" || keyText == "[": command = .columnFirst
            case _ where keyText == "}" || keyText == "]": command = .columnLast
            default: command = nil
            }
        } else if modifiers == [.maskCommand, .maskShift] {
            switch keyCode {
            case KeyCode.one: command = .moveColumnToWorkspace(1)
            case KeyCode.two: command = .moveColumnToWorkspace(2)
            case KeyCode.three: command = .moveColumnToWorkspace(3)
            case KeyCode.four: command = .moveColumnToWorkspace(4)
            case KeyCode.five: command = .moveColumnToWorkspace(5)
            case KeyCode.six: command = .moveColumnToWorkspace(6)
            case KeyCode.seven: command = .moveColumnToWorkspace(7)
            case KeyCode.eight: command = .moveColumnToWorkspace(8)
            case KeyCode.nine: command = .moveColumnToWorkspace(9)
            case KeyCode.h: command = .moveColumnLeft
            case KeyCode.j: command = .moveColumnToWorkspaceDown
            case KeyCode.k: command = .moveColumnToWorkspaceUp
            case KeyCode.l: command = .moveColumnRight
            case KeyCode.leftBracket, KeyCode.home: command = .moveColumnToFirst
            case KeyCode.rightBracket, KeyCode.end: command = .moveColumnToLast
            case _ where keyText == "{" || keyText == "[": command = .moveColumnToFirst
            case _ where keyText == "}" || keyText == "]": command = .moveColumnToLast
            default: command = nil
            }
        } else if modifiers == [.maskCommand, .maskControl] {
            switch keyCode {
            case KeyCode.h: command = .cycleWidthPresetBackward
            case KeyCode.l: command = .cycleWidthPresetForward
            case KeyCode.minus: command = .nudgeWidthNarrower
            case KeyCode.equal: command = .nudgeWidthWider
            default: command = nil
            }
        } else {
            switch keyCode {
            case KeyCode.h: command = .cycleAllWidthPresetsBackward
            case KeyCode.l: command = .cycleAllWidthPresetsForward
            case KeyCode.minus: command = .nudgeAllWidthsNarrower
            case KeyCode.equal: command = .nudgeAllWidthsWider
            default: command = nil
            }
        }

        guard let command else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.perform(command)
        }
        return true
    }

    private func keyboardText(from event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    private func isExcludedKeybinding(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> Bool {
        let excluded = Set((config.excludedKeybindings ?? ScrolliniConfig.fallback.excludedKeybindings ?? [])
            .compactMap(normalizedKeybinding(_:)))
        guard !excluded.isEmpty else {
            return false
        }

        let modifierParts = normalizedModifierParts(from: modifiers)
        for keyName in normalizedKeyNames(keyCode: keyCode, keyText: keyText) {
            let candidate = (modifierParts + [keyName]).joined(separator: "+")
            if excluded.contains(candidate) {
                return true
            }
        }

        return false
    }

    private func normalizedKeybinding(_ binding: String) -> String? {
        let parts = binding
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers = Set<String>()
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert("cmd")
            case "ctrl", "control":
                modifiers.insert("ctrl")
            case "shift":
                modifiers.insert("shift")
            case "alt", "option", "alternate":
                modifiers.insert("alt")
            default:
                key = normalizedKeyName(part)
            }
        }

        guard let key else {
            return nil
        }

        return (orderedModifierParts(from: modifiers) + [key]).joined(separator: "+")
    }

    private func normalizedModifierParts(from modifiers: CGEventFlags) -> [String] {
        var names = Set<String>()
        if modifiers.contains(.maskCommand) {
            names.insert("cmd")
        }
        if modifiers.contains(.maskControl) {
            names.insert("ctrl")
        }
        if modifiers.contains(.maskShift) {
            names.insert("shift")
        }
        if modifiers.contains(.maskAlternate) {
            names.insert("alt")
        }
        return orderedModifierParts(from: names)
    }

    private func orderedModifierParts(from modifiers: Set<String>) -> [String] {
        ["cmd", "ctrl", "shift", "alt"].filter { modifiers.contains($0) }
    }

    private func normalizedKeyNames(keyCode: Int64, keyText: String) -> [String] {
        var names: [String] = []
        let add: (String) -> Void = { name in
            let normalized = self.normalizedKeyName(name)
            if !names.contains(normalized) {
                names.append(normalized)
            }
        }

        if !keyText.isEmpty {
            add(keyText)
        }

        switch keyCode {
        case KeyCode.one: add("1")
        case KeyCode.two: add("2")
        case KeyCode.three: add("3")
        case KeyCode.four: add("4")
        case KeyCode.five: add("5")
        case KeyCode.six: add("6")
        case KeyCode.seven: add("7")
        case KeyCode.eight: add("8")
        case KeyCode.nine: add("9")
        case KeyCode.zero: add("0")
        case KeyCode.h: add("h")
        case KeyCode.j: add("j")
        case KeyCode.k: add("k")
        case KeyCode.l: add("l")
        case KeyCode.minus:
            add("-")
            add("minus")
        case KeyCode.equal:
            add("=")
            add("equal")
        case KeyCode.home: add("home")
        case KeyCode.end: add("end")
        case KeyCode.leftBracket:
            add("[")
            add("{")
        case KeyCode.rightBracket:
            add("]")
            add("}")
        default:
            break
        }

        return names
    }

    private func normalizedKeyName(_ key: String) -> String {
        switch key {
        case "leftbracket", "left-bracket", "openbracket", "open-bracket":
            return "["
        case "rightbracket", "right-bracket", "closebracket", "close-bracket":
            return "]"
        case "leftbrace", "left-brace", "openbrace", "open-brace":
            return "{"
        case "rightbrace", "right-brace", "closebrace", "close-brace":
            return "}"
        case "minus":
            return "-"
        case "equal":
            return "="
        default:
            return key
        }
    }

    fileprivate func handleMouseMoved(_ event: CGEvent) {
        guard hoverFocusEnabled,
              manualResizeElement == nil,
              animationTimer == nil,
              !isApplyingLayout
        else {
            cancelHoverFocus()
            return
        }

        guard CFAbsoluteTimeGetCurrent() >= hoverFocusSuppressedUntil else {
            cancelHoverFocus()
            return
        }

        let point = event.location
        if shouldSuppressHoverFocusUntilRearmed(at: point) {
            cancelHoverFocus()
            return
        }

        guard let target = hoverFocusTarget(at: point) else {
            cancelHoverFocus()
            return
        }

        if target.immediate {
            performHoverFocus(window: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        } else {
            scheduleHoverFocus(for: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        }
    }

    private func handleTrackpadNavigationEvent(_ event: TrackpadNavigationEvent) {
        guard trackpadNavigationEnabled else {
            return
        }

        switch event {
        case .began:
            beginTrackpadCamera()
        case .changed(let delta, let velocity):
            moveTrackpadCamera(delta: delta, velocity: velocity)
        case .ended(let velocity):
            endTrackpadCamera(velocity: velocity)
        }
    }

    private func beginTrackpadCamera() {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        stopTrackpadMomentum()
        stopAnimation(clearPresentation: false)
        rescanWindows(adoptFocused: false)
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        seedTrackpadCamera(viewport: currentViewport())
        startTrackpadRenderLoop()
    }

    private func moveTrackpadCamera(delta: CGPoint, velocity: CGPoint) {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let cameraDelta = trackpadCameraDelta(from: delta, velocity: velocity, viewport: viewport)
        trackpadPendingCameraDelta.width += cameraDelta.width
        trackpadPendingCameraDelta.height += cameraDelta.height
        trackpadLatestCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        trackpadCameraVelocity = trackpadLatestCameraVelocity
        startTrackpadRenderLoop()
    }

    private func endTrackpadCamera(velocity: CGPoint) {
        suppressHoverFocusAfterTrackpadMovement()
        flushTrackpadCameraFrame()
        stopTrackpadRenderLoop()
        let viewport = currentViewport()
        trackpadCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        if abs(trackpadCameraVelocity.x) < abs(trackpadLatestCameraVelocity.x) {
            trackpadCameraVelocity.x = trackpadLatestCameraVelocity.x
        }
        if abs(trackpadCameraVelocity.y) < abs(trackpadLatestCameraVelocity.y) {
            trackpadCameraVelocity.y = trackpadLatestCameraVelocity.y
        }
        guard abs(trackpadCameraVelocity.x) >= 80 || abs(trackpadCameraVelocity.y) >= 80 else {
            settleTrackpadCamera(focusActiveWindow: true)
            return
        }

        startTrackpadMomentum()
    }

    private func trackpadCameraDelta(from delta: CGPoint, velocity: CGPoint, viewport: CGRect) -> CGSize {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGSize(
            width: -delta.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            height: delta.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    private func trackpadCameraVelocity(from velocity: CGPoint, viewport: CGRect) -> CGPoint {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGPoint(
            x: -velocity.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            y: velocity.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    private func trackpadCameraVelocityGain(for velocity: CGPoint) -> CGFloat {
        let speed = hypot(velocity.x, velocity.y)
        let extra = min(max((speed - 0.35) / 1.4, 0), 1.35)
        return 1 + extra
    }

    private func suppressHoverFocusAfterTrackpadMovement() {
        hoverFocusSuppressedUntil = CFAbsoluteTimeGetCurrent() + 0.28
        cancelHoverFocus()
    }

    private func seedTrackpadCamera(viewport: CGRect) {
        if trackpadCameraY == nil {
            trackpadCameraY = CGFloat(activeWorkspace) * viewport.height
        }

        if let workspace = activeWorkspaceObject(), workspace.scrollOffset == nil {
            workspace.scrollOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        }
    }

    private func startTrackpadMomentum() {
        stopTrackpadMomentum()
        trackpadMomentumLastFrameAt = CFAbsoluteTimeGetCurrent()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.stepTrackpadMomentum()
        }
        trackpadMomentumTimer = timer
        timer.resume()
    }

    private func startTrackpadRenderLoop() {
        guard trackpadRenderTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.flushTrackpadCameraFrame()
        }
        trackpadRenderTimer = timer
        timer.resume()
    }

    private func stopTrackpadRenderLoop() {
        trackpadRenderTimer?.cancel()
        trackpadRenderTimer = nil
    }

    private func flushTrackpadCameraFrame() {
        guard abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 else {
            return
        }

        guard manualResizeElement == nil else {
            trackpadPendingCameraDelta = .zero
            stopTrackpadRenderLoop()
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let delta = trackpadPendingCameraDelta
        trackpadPendingCameraDelta = .zero
        _ = applyTrackpadCameraDelta(delta, viewport: viewport)
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
    }

    private func stepTrackpadMomentum() {
        suppressHoverFocusAfterTrackpadMovement()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(max(now - trackpadMomentumLastFrameAt, 1.0 / 120.0), 1.0 / 20.0)
        trackpadMomentumLastFrameAt = now

        let viewport = currentViewport()
        let decay = exp(-trackpadNavigationDeceleration * elapsed)
        trackpadCameraVelocity.x *= decay
        trackpadCameraVelocity.y *= decay

        let cameraDelta = CGSize(
            width: trackpadCameraVelocity.x * elapsed,
            height: trackpadCameraVelocity.y * elapsed
        )
        let clamped = applyTrackpadCameraDelta(cameraDelta, viewport: viewport)
        if clamped.x {
            trackpadCameraVelocity.x = 0
        }
        if clamped.y {
            trackpadCameraVelocity.y = 0
        }

        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)

        if abs(trackpadCameraVelocity.x) < 80, abs(trackpadCameraVelocity.y) < 80 {
            stopTrackpadMomentum()
            settleTrackpadCamera(focusActiveWindow: true)
        }
    }

    private func stopTrackpadMomentum() {
        trackpadMomentumTimer?.cancel()
        trackpadMomentumTimer = nil
    }

    @discardableResult
    private func applyTrackpadCameraDelta(_ delta: CGSize, viewport: CGRect) -> (x: Bool, y: Bool) {
        let currentY = trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height
        let maxY = max(0, CGFloat(max(workspaces.count - 1, 0)) * viewport.height)
        let nextY = min(max(currentY + delta.height, 0), maxY)
        trackpadCameraY = nextY

        let workspaceIndex = trackpadCameraWorkspaceIndex(cameraY: nextY, viewport: viewport)
        var clampedX = false
        if workspaces.indices.contains(workspaceIndex) {
            let workspace = workspaces[workspaceIndex]
            if !workspace.columns.isEmpty {
                let currentX = horizontalCameraOffset(for: workspace, viewport: viewport)
                let maxX = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
                let nextX = min(max(currentX + delta.width, 0), maxX)
                workspace.scrollOffset = nextX
                clampedX = abs(nextX - (currentX + delta.width)) > 0.5
            }
        }

        let clampedY = abs(nextY - (currentY + delta.height)) > 0.5
        return (clampedX, clampedY)
    }

    private func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            trackpadCameraY = nil
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let previousState = captureLayoutState()
        let targetWorkspace = trackpadCameraWorkspaceIndex(
            cameraY: trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height,
            viewport: viewport
        )
        setActiveWorkspace(targetWorkspace)

        if let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty {
            let offset = horizontalCameraOffset(for: workspace, viewport: viewport)
            workspace.activeColumn = closestColumn(to: offset, in: workspace, viewport: viewport)
            workspace.scrollOffset = nil
        }

        trackpadCameraY = nil
        trackpadCameraVelocity = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadPendingCameraDelta = .zero
        hoverFocusRequiresRearm = true
        suppressHoverFocusAfterTrackpadMovement()

        let targetState = captureLayoutState()
        projectLayout(
            focusActiveWindow: focusActiveWindow,
            animated: previousState != targetState,
            from: previousState,
            layoutLockDelay: 0.04
        )
    }

    private func clearTrackpadCamera() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadCameraY = nil
        trackpadCameraVelocity = .zero
    }

    private func freezeTrackpadCameraForTransition() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()

        if abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 {
            let viewport = currentViewport()
            seedTrackpadCamera(viewport: viewport)
            _ = applyTrackpadCameraDelta(trackpadPendingCameraDelta, viewport: viewport)
            trackpadPendingCameraDelta = .zero
        }

        trackpadLatestCameraVelocity = .zero
        trackpadCameraVelocity = .zero
    }

    private func perform(_ command: Command, animateWorkspace: Bool = false) {
        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        rescanWindows(adoptFocused: false)
        let previousState = captureLayoutState()
        var animated = false

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            focusWorkspace(oneBasedIndex)
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .workspaceUp:
            guard setActiveWorkspace(activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .columnLeft:
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = max(workspace.activeColumn - 1, 0)
            workspace.scrollOffset = nil
            animated = true
        case .columnRight:
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = min(workspace.activeColumn + 1, workspace.columns.count - 1)
            workspace.scrollOffset = nil
            animated = true
        case .columnFirst:
            guard focusColumn(at: 0) else {
                return
            }
            animated = true
        case .columnLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard focusColumn(at: workspace.columns.count - 1) else {
                return
            }
            animated = true
        case .moveColumnLeft:
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: -1)
        case .moveColumnRight:
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: 1)
        case .moveColumnToFirst:
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumn(to: 0)
        case .moveColumnToLast:
            seedPresentationFrames(from: previousState)
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            animated = moveActiveColumn(to: workspace.columns.count - 1)
        case .moveColumnToWorkspace(let oneBasedIndex):
            moveActiveColumnToWorkspace(oneBasedIndex: oneBasedIndex)
        case .moveColumnToWorkspaceDown:
            moveActiveColumnToWorkspace(relativeOffset: 1)
        case .moveColumnToWorkspaceUp:
            moveActiveColumnToWorkspace(relativeOffset: -1)
        case .cycleWidthPresetBackward:
            guard cycleActiveWidthPreset(direction: -1) else {
                return
            }
        case .cycleWidthPresetForward:
            guard cycleActiveWidthPreset(direction: 1) else {
                return
            }
        case .nudgeWidthNarrower:
            guard nudgeActiveWidth(by: -0.1) else {
                return
            }
        case .nudgeWidthWider:
            guard nudgeActiveWidth(by: 0.1) else {
                return
            }
        case .cycleAllWidthPresetsBackward:
            guard cycleAllWidthPresets(direction: -1) else {
                return
            }
        case .cycleAllWidthPresetsForward:
            guard cycleAllWidthPresets(direction: 1) else {
                return
            }
        case .nudgeAllWidthsNarrower:
            guard nudgeAllWidths(by: -0.1) else {
                return
            }
        case .nudgeAllWidthsWider:
            guard nudgeAllWidths(by: 0.1) else {
                return
            }
        }

        let newState = captureLayoutState()
        projectLayout(focusActiveWindow: true, animated: animated && previousState != newState, from: previousState)
    }

    private func focusWorkspace(_ oneBasedIndex: Int) {
        guard !workspaces.isEmpty else {
            return
        }

        let requestedIndex = min(max(oneBasedIndex - 1, 0), workspaces.count - 1)
        let targetIndex = workspaceAutoBackAndForth && requestedIndex == activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        setActiveWorkspace(targetIndex)
        activeWorkspaceObject()?.clampFocus()
    }

    private func focusPreviousWorkspace() -> Bool {
        guard let previousIndex = previousWorkspaceIndex(),
              previousIndex != activeWorkspace
        else {
            return false
        }

        setActiveWorkspace(previousIndex)
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    @discardableResult
    private func setActiveWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        guard !workspaces.isEmpty else {
            activeWorkspace = 0
            previousWorkspace = nil
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let currentWorkspace = activeWorkspaceObject()
        activeWorkspace = targetIndex
        if rememberPrevious {
            previousWorkspace = currentWorkspace
        }
        return true
    }

    private func previousWorkspaceIndex() -> Int? {
        guard let previousWorkspace else {
            return nil
        }

        return workspaces.firstIndex(where: { $0 === previousWorkspace })
    }

    private func focusColumn(at requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    private func moveActiveColumnHorizontally(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        return moveActiveColumn(to: workspace.activeColumn + delta)
    }

    private func moveActiveColumn(to requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard sourceIndex != targetIndex else {
            return false
        }
        guard workspace.columns.indices.contains(targetIndex) else {
            return false
        }

        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    private func cycleActiveWidthPreset(direction: Int) -> Bool {
        guard let window = activeWindow() else {
            return false
        }

        guard let target = widthPreset(after: widthRatio(for: window), direction: direction) else {
            return false
        }

        return setActiveWindowWidthRatio(target)
    }

    private func cycleAllWidthPresets(direction: Int) -> Bool {
        guard let window = activeWindow(),
              let target = widthPreset(after: widthRatio(for: window), direction: direction)
        else {
            return false
        }

        return setAllWindowWidthRatios(target)
    }

    private func widthPreset(after current: CGFloat, direction: Int) -> CGFloat? {
        let presets = widthPresetRatios
        guard !presets.isEmpty else {
            return nil
        }

        if direction >= 0 {
            return presets.first(where: { $0 > current + 0.005 }) ?? presets[0]
        }

        return presets.last(where: { $0 < current - 0.005 }) ?? presets[presets.count - 1]
    }

    private func nudgeActiveWidth(by delta: CGFloat) -> Bool {
        guard let window = activeWindow() else {
            return false
        }
        return setActiveWindowWidthRatio(widthRatio(for: window) + delta)
    }

    private func nudgeAllWidths(by delta: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(widthRatio(for: window) + delta, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        presentationFrames.removeAll()
        return true
    }

    private func setActiveWindowWidthRatio(_ ratio: CGFloat) -> Bool {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        guard setWidthRatio(ratio, for: window) else {
            return false
        }

        workspace.scrollOffset = nil
        presentationFrames.removeAll()
        return true
    }

    private func setAllWindowWidthRatios(_ ratio: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(ratio, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        presentationFrames.removeAll()
        return true
    }

    private func setWidthRatio(_ ratio: CGFloat, for window: ManagedWindow) -> Bool {
        let oldRatio = widthRatio(for: window)
        let newRatio = ratio.clampedManualWidthRatio
        guard abs(oldRatio - newRatio) >= 0.005 else {
            return false
        }

        window.manualWidthRatio = newRatio
        return true
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(relativeOffset: Int) -> Bool {
        let targetIndex = activeWorkspace + relativeOffset
        return moveActiveColumnToWorkspace(zeroBasedIndex: targetIndex)
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(oneBasedIndex: Int) -> Bool {
        let zeroBased = max(0, oneBasedIndex - 1)
        return moveActiveColumnToWorkspace(zeroBasedIndex: zeroBased)
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(zeroBasedIndex requestedIndex: Int) -> Bool {
        guard workspaces.indices.contains(activeWorkspace),
              let sourceWorkspace = activeWorkspaceObject(),
              !sourceWorkspace.columns.isEmpty
        else {
            return false
        }

        sourceWorkspace.clampFocus()
        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let targetWorkspace = workspaces[targetIndex]
        let movingWindow = sourceWorkspace.columns.remove(at: sourceWorkspace.activeColumn)
        sourceWorkspace.scrollOffset = nil
        sourceWorkspace.clampFocus()

        targetWorkspace.clampFocus()
        let insertionIndex = targetWorkspace.columns.isEmpty
            ? 0
            : min(targetWorkspace.activeColumn + 1, targetWorkspace.columns.count)
        targetWorkspace.columns.insert(movingWindow, at: insertionIndex)
        targetWorkspace.activeColumn = insertionIndex
        targetWorkspace.scrollOffset = nil

        setActiveWorkspace(targetIndex)
        ensureTrailingEmptyWorkspace()
        activeWorkspace = workspaces.firstIndex(where: { $0 === targetWorkspace }) ?? activeWorkspace
        return true
    }

    private func activeWorkspaceObject() -> Workspace? {
        guard workspaces.indices.contains(activeWorkspace) else {
            return nil
        }
        return workspaces[activeWorkspace]
    }

    private func captureLayoutState() -> LayoutState {
        LayoutState(
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            cameraY: trackpadCameraY
        )
    }

    private func seedPresentationFrames(from state: LayoutState) {
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        presentationFrames = Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0.frame) })
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard !isApplyingLayout else {
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.adoptFocusedWindow(pid: app.processIdentifier)
        }
        adoptFocusedWindow(pid: app.processIdentifier)
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rescanWindows(adoptFocused: true)
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.projectLayout(focusActiveWindow: false)
        }
    }

    private func rescanWindows(adoptFocused: Bool) {
        let discovered = discoverWindows()
        var changed = false

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                if behavior(for: window) == .ignore {
                    SkyLight.shared.setAlpha(1, for: window.windowID)
                }
                removeWindow(window)
                changed = true
            }
        }

        for found in discovered {
            if let existing = allWindows().first(where: { sameWindow($0.element, found.element) }) {
                existing.title = found.title
                existing.appName = found.appName
                existing.bundleID = found.bundleID

                let shouldFloat = behavior(for: existing) == .float
                let isFloating = floatingWindows.contains(where: { $0 === existing })
                if shouldFloat != isFloating {
                    removeWindow(existing)
                    if shouldFloat {
                        insertFloatingWindow(existing)
                    } else {
                        insertNewWindow(existing)
                    }
                    changed = true
                }
            } else {
                if behavior(for: found) == .float {
                    insertFloatingWindow(found)
                } else {
                    insertNewWindow(found)
                }
                changed = true
            }
        }

        ensureTrailingEmptyWorkspace()

        if adoptFocused {
            adoptFocusedWindow(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        } else if changed {
            projectLayout(focusActiveWindow: false)
        }
    }

    private func discoverWindows() -> [ManagedWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else {
                continue
            }
            let pid = app.processIdentifier
            guard pid != currentPID else {
                continue
            }

            startObservingApp(pid: pid)

            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }

            for element in axWindows where isManageableWindow(element) || isKnownWindow(element) {
                let title = axString(element, kAXTitleAttribute) ?? ""
                let appName = app.localizedName ?? "pid \(pid)"
                let windowID = SkyLight.shared.windowID(for: element)
                let window = ManagedWindow(
                    element: element,
                    pid: pid,
                    windowID: windowID,
                    bundleID: app.bundleIdentifier,
                    appName: appName,
                    title: title
                )
                guard behavior(for: window) != .ignore else {
                    SkyLight.shared.setAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    private func isManageableWindow(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

        if axBool(element, kAXMinimizedAttribute) == true {
            return false
        }

        guard let frame = axFrame(element), frame.width >= 120, frame.height >= 80 else {
            return false
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionError == .success && sizeError == .success && positionSettable.boolValue && sizeSettable.boolValue
    }

    private func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

    private func insertNewWindow(_ window: ManagedWindow) {
        let workspace = activeWorkspaceObject() ?? workspaces[0]
        workspace.clampFocus()

        let insertionIndex: Int
        if workspace.columns.isEmpty {
            insertionIndex = 0
        } else {
            insertionIndex = min(workspace.activeColumn + 1, workspace.columns.count)
        }

        workspace.columns.insert(window, at: insertionIndex)
        workspace.activeColumn = insertionIndex
        workspace.scrollOffset = nil
        if let workspaceIndex = workspaces.firstIndex(where: { $0 === workspace }) {
            setActiveWorkspace(workspaceIndex, rememberPrevious: false)
        }
        ensureTrailingEmptyWorkspace()
        projectLayout(focusActiveWindow: true)
    }

    private func insertFloatingWindow(_ window: ManagedWindow) {
        if !floatingWindows.contains(where: { $0 === window }) {
            floatingWindows.append(window)
        }
        projectLayout(focusActiveWindow: false)
    }

    private func removeWindow(_ window: ManagedWindow) {
        if let index = floatingWindows.firstIndex(where: { $0 === window }) {
            floatingWindows.remove(at: index)
            return
        }

        for workspace in workspaces {
            if let index = workspace.columns.firstIndex(where: { $0 === window }) {
                workspace.columns.remove(at: index)
                if workspace.activeColumn >= index {
                    workspace.activeColumn = max(0, workspace.activeColumn - 1)
                }
                workspace.scrollOffset = nil
                workspace.clampFocus()
                break
            }
        }
        ensureTrailingEmptyWorkspace()
    }

    private func ensureTrailingEmptyWorkspace() {
        if workspaces.isEmpty {
            workspaces = [Workspace()]
            activeWorkspace = 0
            previousWorkspace = nil
            return
        }

        if !workspaces.last!.isEmpty {
            workspaces.append(Workspace())
        }

        if workspaces.count > 1 {
            var index = workspaces.count - 2
            while index >= 0 {
                if index != activeWorkspace && workspaces[index].isEmpty {
                    workspaces.remove(at: index)
                    if activeWorkspace > index {
                        activeWorkspace -= 1
                    }
                }
                if index == 0 {
                    break
                }
                index -= 1
            }
        }

        activeWorkspace = min(max(activeWorkspace, 0), workspaces.count - 1)
        for workspace in workspaces {
            workspace.clampFocus()
        }
    }

    private var animationDuration: TimeInterval {
        TimeInterval(config.animationDurationMS ?? ScrolliniConfig.fallback.animationDurationMS ?? 240) / 1000
    }

    private var hoverFocusEnabled: Bool {
        config.hoverToFocus ?? ScrolliniConfig.fallback.hoverToFocus ?? true
    }

    private var hoverFocusDelay: TimeInterval {
        TimeInterval(config.hoverFocusDelayMS ?? ScrolliniConfig.fallback.hoverFocusDelayMS ?? 120) / 1000
    }

    private var hoverFocusMaxScrollRatio: CGFloat {
        config.hoverFocusMaxScrollRatio ?? ScrolliniConfig.fallback.hoverFocusMaxScrollRatio ?? 0.15
    }

    private var workspaceAutoBackAndForth: Bool {
        config.workspaceAutoBackAndForth ?? ScrolliniConfig.fallback.workspaceAutoBackAndForth ?? true
    }

    private var centerFocusedColumn: Bool {
        config.centerFocusedColumn ?? ScrolliniConfig.fallback.centerFocusedColumn ?? true
    }

    private var trackpadNavigationEnabled: Bool {
        config.trackpadNavigation ?? ScrolliniConfig.fallback.trackpadNavigation ?? true
    }

    private var trackpadNavigationFingers: Int {
        config.trackpadNavigationFingers ?? ScrolliniConfig.fallback.trackpadNavigationFingers ?? 3
    }

    private var trackpadNavigationSensitivity: CGFloat {
        config.trackpadNavigationSensitivity ?? ScrolliniConfig.fallback.trackpadNavigationSensitivity ?? 1.6
    }

    private var trackpadNavigationDeceleration: CGFloat {
        config.trackpadNavigationDeceleration ?? ScrolliniConfig.fallback.trackpadNavigationDeceleration ?? 5.5
    }

    private var trackpadNavigationInvertX: Bool {
        config.trackpadNavigationInvertX ?? ScrolliniConfig.fallback.trackpadNavigationInvertX ?? false
    }

    private var trackpadNavigationInvertY: Bool {
        config.trackpadNavigationInvertY ?? ScrolliniConfig.fallback.trackpadNavigationInvertY ?? false
    }

    private var widthPresetRatios: [CGFloat] {
        config.presetWidthRatios ?? ScrolliniConfig.fallback.presetWidthRatios ?? [0.5, 0.67, 0.8, 1.0]
    }

    private func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        layoutLockDelay: TimeInterval = 0.08
    ) {
        let viewport = currentViewport()
        writeRestoreSnapshot(viewport: viewport)

        let targetState = captureLayoutState()
        if animated, animationDuration > 0, let previousState {
            animateLayout(from: previousState, to: targetState, viewport: viewport, focusActiveWindow: focusActiveWindow)
            return
        }

        stopAnimation(clearPresentation: true)
        isApplyingLayout = true
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow)
        restoreFloatingVisibility()
        releaseLayoutLock(after: layoutLockDelay)
    }

    private func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let stateActiveWorkspace = min(max(state.activeWorkspace, 0), max(workspaces.count - 1, 0))
        let cameraY = state.cameraY ?? CGFloat(stateActiveWorkspace) * viewport.height
        let cameraWorkspace = trackpadCameraWorkspaceIndex(cameraY: cameraY, viewport: viewport)
        var layout: [LayoutItem] = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let scrollOffset = scrollOffset(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let strip = stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: activeColumn,
                scrollOffset: scrollOffset
            )
            let rowOffset = CGFloat(workspaceIndex) * viewport.height - cameraY

            for (columnIndex, window) in workspace.columns.enumerated() {
                let frame: CGRect
                var projected = strip[columnIndex]
                projected.origin.y += rowOffset

                let visible = projected.intersects(viewport)
                if visible || !parkHidden {
                    frame = projected
                } else if workspaceIndex == cameraWorkspace {
                    frame = parkedFrame(for: window, viewport: viewport, beforeActive: columnIndex < activeColumn)
                } else {
                    frame = parkedFrame(
                        for: window,
                        viewport: viewport,
                        beforeActive: CGFloat(workspaceIndex) * viewport.height < cameraY
                    )
                }

                layout.append(LayoutItem(window: window, frame: frame, visible: visible))
            }
        }

        return layout
    }

    private func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    private func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    private func trackpadCameraWorkspaceIndex(cameraY: CGFloat, viewport: CGRect) -> Int {
        guard viewport.height > 0, !workspaces.isEmpty else {
            return 0
        }

        return min(max(Int(round(cameraY / viewport.height)), 0), workspaces.count - 1)
    }

    private func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) {
        for item in layout where !item.visible {
            SkyLight.shared.setAlpha(0, for: item.window.windowID)
        }

        if focusActiveWindow, let activeWindow = self.activeWindow() {
            let inactiveVisible = layout.filter { $0.visible && $0.window !== activeWindow }
            for item in inactiveVisible {
                setAXFrame(item.frame, for: item.window.element)
                SkyLight.shared.setAlpha(1, for: item.window.windowID)
            }

            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                setAXFrame(activeItem.frame, for: activeWindow.element)
                SkyLight.shared.setAlpha(1, for: activeWindow.windowID)
            }
        } else {
            for item in layout where item.visible {
                setAXFrame(item.frame, for: item.window.element)
                SkyLight.shared.setAlpha(1, for: item.window.windowID)
            }
        }

        for item in layout where !item.visible {
            setAXFrame(item.frame, for: item.window.element)
            SkyLight.shared.setAlpha(0, for: item.window.windowID)
        }

        if focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow)
        }
    }

    private func restoreFloatingVisibility() {
        for window in floatingWindows {
            SkyLight.shared.setAlpha(1, for: window.windowID)
        }
    }

    private func hoverFocusTarget(
        at point: CGPoint
    ) -> (window: ManagedWindow, workspaceIndex: Int, columnIndex: Int, immediate: Bool)? {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return nil
        }

        let viewport = currentViewport()
        guard viewportContains(point, viewport: viewport) else {
            return nil
        }

        let state = captureLayoutState()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        for item in layout where item.visible && item.frame.contains(point) {
            guard let loc = location(of: item.window.element), loc.workspace == activeWorkspace else {
                continue
            }
            if loc.column == workspace.activeColumn {
                return nil
            }
            let immediate = hoverFocusEdgeTrigger(
                targetColumn: loc.column,
                activeColumn: workspace.activeColumn,
                point: point,
                viewport: viewport
            )
            guard immediate || hoverFocusCanScroll(
                toColumn: loc.column,
                in: workspace,
                workspaceIndex: loc.workspace,
                state: state,
                viewport: viewport,
                targetFrame: item.frame,
                point: point
            ) else {
                continue
            }
            return (item.window, loc.workspace, loc.column, immediate)
        }

        return nil
    }

    private func viewportContains(_ point: CGPoint, viewport: CGRect) -> Bool {
        point.x >= viewport.minX
            && point.x <= viewport.maxX
            && point.y >= viewport.minY
            && point.y <= viewport.maxY
    }

    private func hoverFocusEdgeTrigger(
        targetColumn: Int,
        activeColumn: Int,
        point: CGPoint,
        viewport: CGRect
    ) -> Bool {
        if targetColumn > activeColumn {
            return point.x >= viewport.maxX - hoverFocusEdgeTriggerWidth
        }
        if targetColumn < activeColumn {
            return point.x <= viewport.minX + hoverFocusEdgeTriggerWidth
        }
        return false
    }

    private func hoverFocusCanScroll(
        toColumn targetColumn: Int,
        in workspace: Workspace,
        workspaceIndex: Int,
        state: LayoutState,
        viewport: CGRect,
        targetFrame: CGRect,
        point: CGPoint
    ) -> Bool {
        guard viewport.width > 0 else {
            return false
        }

        guard workspace.columns.indices.contains(targetColumn) else {
            return false
        }

        let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
        let requiredDepth = viewport.width * hoverFocusMaxScrollRatio
        guard requiredDepth > 0 else {
            return false
        }

        let visibleTargetFrame = targetFrame.intersection(viewport)
        guard !visibleTargetFrame.isNull else {
            return false
        }

        if targetColumn > activeColumn {
            return point.x - visibleTargetFrame.minX >= requiredDepth
        }
        if targetColumn < activeColumn {
            return visibleTargetFrame.maxX - point.x >= requiredDepth
        }
        return false
    }

    private func scheduleHoverFocus(for window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        let id = ObjectIdentifier(window)
        if hoverFocusTarget == id {
            return
        }

        cancelHoverFocus()
        hoverFocusTarget = id

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + hoverFocusDelay, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            performHoverFocus(window: window, workspaceIndex: workspaceIndex, columnIndex: columnIndex)
        }
        hoverFocusTimer = timer
        timer.resume()
    }

    private func performHoverFocus(window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        hoverFocusTimer?.cancel()
        hoverFocusTimer = nil
        hoverFocusTarget = nil

        guard hoverFocusEnabled,
              manualResizeElement == nil,
              animationTimer == nil,
              workspaces.indices.contains(workspaceIndex),
              workspaces[workspaceIndex].columns.indices.contains(columnIndex),
              workspaces[workspaceIndex].columns[columnIndex] === window
        else {
            return
        }

        let workspace = workspaces[workspaceIndex]
        guard activeWorkspace != workspaceIndex || workspace.activeColumn != columnIndex else {
            return
        }

        freezeTrackpadCameraForTransition()
        let previousState = captureLayoutState()
        trackpadCameraY = nil
        setActiveWorkspace(workspaceIndex)
        workspace.activeColumn = columnIndex
        workspace.scrollOffset = nil
        let newState = captureLayoutState()
        hoverFocusRequiresRearm = true
        projectLayout(focusActiveWindow: true, animated: previousState != newState, from: previousState)
    }

    private func cancelHoverFocus() {
        hoverFocusTimer?.cancel()
        hoverFocusTimer = nil
        hoverFocusTarget = nil
    }

    private func shouldSuppressHoverFocusUntilRearmed(at point: CGPoint) -> Bool {
        guard hoverFocusRequiresRearm else {
            return false
        }

        if hoverFocusTarget(at: point) == nil {
            hoverFocusRequiresRearm = false
            return false
        }

        return true
    }

    private func animateLayout(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool
    ) {
        stopAnimation(clearPresentation: false)
        isApplyingLayout = true

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys)

        let motions = windowIDs.compactMap { id -> WindowMotion? in
            guard let window = startByWindow[id]?.window ?? targetByWindow[id]?.window else {
                return nil
            }
            let startFrame = presentationFrames[id] ?? startByWindow[id]?.frame ?? targetByWindow[id]?.frame
            let endFrame = targetByWindow[id]?.frame ?? startFrame
            guard let startFrame, let endFrame else {
                return nil
            }
            let participates = startFrame.union(endFrame).intersects(viewport)
            let sizeStable = abs(startFrame.width - endFrame.width) < 0.5
                && abs(startFrame.height - endFrame.height) < 0.5
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                participates: participates,
                sizeStable: sizeStable
            )
        }

        guard !motions.isEmpty else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility()
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        for motion in motions {
            SkyLight.shared.setAlpha(motion.participates ? 1 : 0, for: motion.window.windowID)
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let linearProgress = min(max(elapsed / animationDuration, 0), 1)
            let easedProgress = softSettleCurve(CGFloat(linearProgress))
            applyAnimationFrame(motions, progress: easedProgress, viewport: viewport)
            restoreFloatingVisibility()

            if linearProgress >= 1 {
                animationTimer?.cancel()
                animationTimer = nil
                applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
                restoreFloatingVisibility()
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
        }

        animationTimer = timer
        timer.resume()
    }

    private func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }

    private func applyAnimationFrame(_ motions: [WindowMotion], progress: CGFloat, viewport: CGRect) {
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for motion in motions {
            let id = ObjectIdentifier(motion.window)
            guard motion.participates else {
                continue
            }

            let frame = interpolate(from: motion.startFrame, to: motion.endFrame, progress: progress)
            nextPresentationFrames[id] = frame

            if motion.sizeStable {
                setAXPosition(frame.origin, for: motion.window.element)
            } else {
                setAXFrame(frame, for: motion.window.element)
            }
        }

        presentationFrames = nextPresentationFrames
    }

    private func stopAnimation(clearPresentation: Bool) {
        animationTimer?.cancel()
        animationTimer = nil
        if clearPresentation {
            presentationFrames.removeAll()
        }
    }

    private func releaseLayoutLock(after delay: TimeInterval = 0.08) {
        guard delay > 0 else {
            isApplyingLayout = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, animationTimer == nil else {
                return
            }
            isApplyingLayout = false
        }
    }

    private func softSettleCurve(_ progress: CGFloat) -> CGFloat {
        cubicBezier(progress, x1: 0.16, y1: 0.0, x2: 0.18, y2: 1.0)
    }

    private func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
        guard progress > 0 else {
            return 0
        }
        guard progress < 1 else {
            return 1
        }

        var t = progress
        for _ in 0..<5 {
            let x = bezierCoordinate(t, p1: x1, p2: x2) - progress
            let derivative = bezierDerivative(t, p1: x1, p2: x2)
            if abs(derivative) < 0.0001 {
                break
            }
            t = min(max(t - x / derivative, 0), 1)
        }

        return bezierCoordinate(t, p1: y1, p2: y2)
    }

    private func bezierCoordinate(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t
    }

    private func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * p1
            + 6 * inverse * t * (p2 - p1)
            + 3 * t * t * (1 - p2)
    }

    private func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private func stripFrames(
        for workspace: Workspace,
        viewport: CGRect,
        activeColumn: Int,
        scrollOffset preferredScrollOffset: CGFloat?
    ) -> [CGRect] {
        guard !workspace.columns.isEmpty else {
            return []
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let scrollOffset = preferredScrollOffset ?? defaultScrollOffset(
            metrics: metrics,
            activeColumn: activeColumn,
            viewport: viewport
        )
        return workspace.columns.indices.map { index in
            CGRect(
                x: viewport.minX + metrics.origins[index] - scrollOffset,
                y: viewport.minY,
                width: metrics.widths[index],
                height: viewport.height
            )
        }
    }

    private func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
        var virtualX: CGFloat = 0
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []

        for window in workspace.columns {
            origins.append(virtualX)
            let width = viewport.width * widthRatio(for: window)
            widths.append(width)
            virtualX += width
        }

        return (origins, widths)
    }

    private func horizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        if let scrollOffset = workspace.scrollOffset {
            return min(max(scrollOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let activeColumn = min(max(workspace.activeColumn, 0), max(workspace.columns.count - 1, 0))
        return defaultScrollOffset(metrics: metrics, activeColumn: activeColumn, viewport: viewport)
    }

    private func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let contentWidth = zip(metrics.origins, metrics.widths)
            .map { $0.0 + $0.1 }
            .max() ?? viewport.width
        let lastColumnOffset = defaultScrollOffset(
            metrics: metrics,
            activeColumn: workspace.columns.count - 1,
            viewport: viewport
        )
        return max(0, contentWidth - viewport.width, lastColumnOffset)
    }

    private func closestColumn(to scrollOffset: CGFloat, in workspace: Workspace, viewport: CGRect) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let cameraCenter = scrollOffset + viewport.width / 2
        var closestIndex = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for index in workspace.columns.indices {
            guard metrics.origins.indices.contains(index), metrics.widths.indices.contains(index) else {
                continue
            }

            let columnCenter = metrics.origins[index] + metrics.widths[index] / 2
            let distance = abs(columnCenter - cameraCenter)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        return closestIndex
    }

    private func defaultScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect
    ) -> CGFloat {
        guard centerFocusedColumn,
              activeColumn > 0,
              metrics.origins.indices.contains(activeColumn),
              metrics.widths.indices.contains(activeColumn)
        else {
            return metrics.origins.indices.contains(activeColumn) ? metrics.origins[activeColumn] : 0
        }

        let activeCenter = metrics.origins[activeColumn] + metrics.widths[activeColumn] / 2
        return max(0, activeCenter - viewport.width / 2)
    }

    private func parkedFrame(for window: ManagedWindow, viewport: CGRect, beforeActive: Bool) -> CGRect {
        let width = viewport.width * widthRatio(for: window)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height)
        frame.origin.x = beforeActive
            ? viewport.minX - width + parkedSliverWidth
            : viewport.maxX - parkedSliverWidth
        return frame
    }

    private func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        for rule in config.rules where rule.matches(window) {
            if let widthRatio = rule.widthRatio {
                return widthRatio.clampedWidthRatio
            }
        }
        return config.defaultWidthRatio.clampedWidthRatio
    }

    private func behavior(for window: ManagedWindow) -> WindowBehavior {
        for rule in config.rules where rule.matches(window) {
            if let behavior = rule.behavior {
                return behavior
            }
        }
        return .tile
    }

    private func currentViewport() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGDisplayBounds(CGMainDisplayID())
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        return CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
    }

    private func focus(_ window: ManagedWindow) {
        SkyLight.shared.setAlpha(1, for: window.windowID)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func activeWindow() -> ManagedWindow? {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return nil
        }
        workspace.clampFocus()
        return workspace.columns[workspace.activeColumn]
    }

    private func allWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns) + floatingWindows
    }

    private func tiledWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns)
    }

    private func restoreManagedWindowsForExit() {
        let viewport = currentViewport()
        for window in tiledWindows() {
            SkyLight.shared.setAlpha(1, for: window.windowID)
            setAXFrame(viewport, for: window.element)
        }
        restoreFloatingVisibility()
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    private func writeRestoreSnapshot(viewport: CGRect) {
        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            return
        }

        let snapshot = RestoreSnapshot(windowIDs: ids, viewport: RectSnapshot(viewport))
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: restoreStateURL, options: [.atomic])
    }

    private func location(of element: AXUIElement) -> (workspace: Int, column: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() where sameWindow(window.element, element) {
                return (workspaceIndex, columnIndex)
            }
        }
        return nil
    }

    private func tiledWindowLocation(
        for element: AXUIElement
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    private func tiledWindow(for element: AXUIElement) -> ManagedWindow? {
        tiledWindowLocation(for: element)?.window
    }

    private func updateManualWidthRatio(for element: AXUIElement) -> Bool {
        guard let location = tiledWindowLocation(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let ratio = (frame.width / viewport.width).clampedManualWidthRatio
        let previousRatio = location.window.manualWidthRatio
        let oldScrollOffset = location.workspace.scrollOffset
        location.window.manualWidthRatio = ratio

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        location.workspace.scrollOffset = newScrollOffset
        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        presentationFrames[ObjectIdentifier(location.window)] = frame

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
        {
            return false
        }

        return true
    }

    private func beginOrContinueManualResize(for element: AXUIElement) {
        cancelHoverFocus()
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility()
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        manualResizeElement = element
        manualResizeEndTimer?.cancel()
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element) {
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
        }

        scheduleManualResizeEnd(for: element)
    }

    private func scheduleManualResizeEnd(for element: AXUIElement) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            manualResizeEndTimer?.cancel()
            manualResizeEndTimer = nil

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                _ = updateManualWidthRatio(for: element)
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                manualResizeElement = nil
            }
        }

        manualResizeEndTimer = timer
        timer.resume()
    }

    private func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeElement.map { sameWindow($0, element) } ?? false
    }

    private func frameWidthDiffersFromLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let frameRatio = (frame.width / viewport.width).clampedManualWidthRatio
        return abs(frameRatio - widthRatio(for: window)) >= 0.005
    }

    private func adoptFocusedWindow(pid: pid_t?) {
        guard let pid else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let focused = value else {
            return
        }

        let focusedElement = focused as! AXUIElement
        if floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            projectLayout(focusActiveWindow: false)
            return
        }

        if let loc = location(of: focusedElement) {
            clearTrackpadCamera()
            setActiveWorkspace(loc.workspace)
            let workspace = workspaces[loc.workspace]
            workspace.activeColumn = loc.column
            workspace.scrollOffset = nil
            projectLayout(focusActiveWindow: false)
        }
    }

    private func startObservingApp(pid: pid_t) {
        guard observers[pid] == nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            rescanWindows(adoptFocused: false)
            adoptFocusedWindow(pid: pid)
        case kAXCreatedNotification, kAXUIElementDestroyedNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
        case kAXWindowResizedNotification:
            guard tiledWindow(for: element) != nil else {
                restoreFloatingVisibility()
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility()
                    return
                }
                if frameWidthDiffersFromLayout(for: element) {
                    beginOrContinueManualResize(for: element)
                    return
                }
                if let frame = axFrame(element) {
                    presentationFrames[ObjectIdentifier(window)] = frame
                }
                projectLayout(focusActiveWindow: false)
            }
        default:
            break
        }
    }

    private func sameWindow(_ left: AXUIElement, _ right: AXUIElement) -> Bool {
        CFEqual(left, right)
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .keyDown || type == .mouseMoved else {
        return Unmanaged.passUnretained(event)
    }

    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<Scrollini>.fromOpaque(refcon).takeUnretainedValue()
    if type == .mouseMoved {
        app.handleMouseMoved(event)
        return Unmanaged.passUnretained(event)
    }

    if app.handleKeyEvent(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let app = Unmanaged<Scrollini>.fromOpaque(refcon).takeUnretainedValue()
    app.handleAXNotification(notification as String, element: element)
}
