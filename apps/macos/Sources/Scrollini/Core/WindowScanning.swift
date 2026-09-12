import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    @objc func applicationActivated(_ notification: Notification) {
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        guard !reconcileExpectedFocusChange(pid: app.processIdentifier) else {
            return
        }
        guard !shouldSuppressFocusedWindowAdoption else {
            return
        }

        if adoptFocusedWindow(pid: app.processIdentifier, respectFocusSuppression: true) {
            return
        }

        // Newly launched applications can activate before their first window reaches the model.
        // Defer discovery for that uncommon case instead of rescanning every application after
        // each ordinary Cmd-Tab activation.
        scheduleRescan(after: 0.08, adoptFocused: true)
    }

    @objc func applicationLaunched(_ notification: Notification) {
        refreshRunningApplications()
        scheduleRescan(after: 0.4, adoptFocused: true)
    }

    @objc func applicationTerminated(_ notification: Notification) {
        refreshRunningApplications()
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            stopObservingApp(pid: app.processIdentifier)
        }
        scheduleRescan(after: 0.1, adoptFocused: false, projectLayoutAfter: true)
    }

    func scheduleRescan(
        after delay: TimeInterval,
        adoptFocused: Bool,
        projectLayoutAfter: Bool = false
    ) {
        scheduledRescanAdoptFocused = scheduledRescanAdoptFocused || adoptFocused
        scheduledRescanProjectLayout = scheduledRescanProjectLayout || projectLayoutAfter
        cancelTimer(&scheduledRescanTimer)

        scheduledRescanTimer = makeMainTimer(
            deadline: .now() + delay,
            leeway: .milliseconds(25)
        ) { [weak self] in
            self?.runScheduledRescan()
        }
    }

    func runScheduledRescan() {
        cancelTimer(&scheduledRescanTimer)

        let adoptFocused = scheduledRescanAdoptFocused
        let projectLayoutAfter = scheduledRescanProjectLayout
        scheduledRescanAdoptFocused = false
        scheduledRescanProjectLayout = false

        rescanWindows(adoptFocused: adoptFocused)
        if projectLayoutAfter {
            projectLayout(focusActiveWindow: false)
        }
    }

    /// A fingerprint of what the window server is holding right now: one call into WindowServer,
    /// no accessibility traffic at all. It answers "has anything opened, closed, or changed
    /// on-screen state" for a small fraction of what a real sweep costs.
    func windowServerSignature() -> [UInt64] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var signature: [UInt64] = []
        signature.reserveCapacity(entries.count)
        for entry in entries {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t
            else {
                continue
            }

            // Minimizing takes a window out of the on-screen set without destroying it, and that
            // has to register as a change or a minimized column would stay in the strip.
            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            var token = UInt64(UInt32(bitPattern: pid)) << 32 | UInt64(number)
            if onScreen {
                token |= 1 << 63
            }
            signature.append(token)
        }

        signature.sort()
        return signature
    }

    /// The once-a-second safety net behind the accessibility notifications that already rescan
    /// the moment a window is created or destroyed. A real sweep costs a synchronous round trip
    /// into every running application plus several more for every window it does not already
    /// manage, and the tick used to pay that every second for the life of the session whether or
    /// not anything had happened. The fingerprint decides. A full sweep still runs on a slower
    /// cadence so that what the fingerprint cannot see, a retitled window above all, does not go
    /// stale indefinitely.
    func rescanWindowsIfChanged(adoptFocused: Bool, allowPeriodicFullSweep: Bool = true) {
        let signature = windowServerSignature()
        let now = CFAbsoluteTimeGetCurrent()

        if !adoptFocused,
           !signature.isEmpty,
           signature == lastWindowServerSignature,
           (!allowPeriodicFullSweep || now - lastFullRescanAt < fullRescanInterval)
        {
            return
        }

        rescanWindows(adoptFocused: adoptFocused, knownWindowServerSignature: signature)
    }

    func rescanWindows(adoptFocused: Bool, knownWindowServerSignature: [UInt64]? = nil) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        let discovered = discoverWindows()
        lastWindowServerSignature = knownWindowServerSignature ?? windowServerSignature()
        lastFullRescanAt = CFAbsoluteTimeGetCurrent()
        var knownWindows = allWindows()
        var changed = false

        for window in knownWindows {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                if behavior(for: window) == .ignore {
                    setWindowAlpha(1, for: window.windowID)
                }
                removeWindow(window)
                knownWindows.removeAll { $0 === window }
                changed = true
            }
        }

        for found in discovered {
            if let existing = knownWindows.first(where: { sameWindow($0.element, found.element) }) {
                existing.title = found.title
                existing.appName = found.appName
                existing.bundleID = found.bundleID

                let shouldFloat = behavior(for: existing) == .float
                let isFloating = floatingWindows.contains(where: { $0 === existing })
                if shouldFloat != isFloating {
                    removeWindow(existing)
                    if shouldFloat {
                        insertFloatingWindow(existing, applyLayout: false)
                    } else {
                        insertNewWindow(existing, applyLayout: false, focusNewWindow: false)
                    }
                    changed = true
                }
            } else {
                if behavior(for: found) == .float {
                    insertFloatingWindow(found, applyLayout: false)
                } else {
                    insertNewWindow(found, applyLayout: false, focusNewWindow: false)
                }
                knownWindows.append(found)
                changed = true
            }
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        ensureTrailingEmptyWorkspace()
        pruneAppliedLayoutCache()

        if adoptFocused {
            let suppressFocusedAdoption = shouldSuppressFocusedWindowAdoption
            let adoptedFocusedWindow = suppressFocusedAdoption
                ? false
                : adoptFocusedWindow(
                    pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    applyLayout: false,
                    respectFocusSuppression: true
                )
            let restoredPersistentFocus = !suppressFocusedAdoption && !adoptedFocusedWindow
                ? restorePersistentFocusedWindow()
                : false
            if changed || restoredPersistentLayout || adoptedFocusedWindow || restoredPersistentFocus {
                projectLayout(
                    focusActiveWindow: restoredPersistentFocus,
                    layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08
                )
            }
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
    }

    func discoverWindows() -> [ManagedWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        // Indexed once per scan. The old membership test walked every managed window for every
        // candidate the system reported, which is quadratic in the window count on every tick.
        var knownByElement: [AXElementKey: ManagedWindow] = [:]
        for window in allWindows() {
            knownByElement[AXElementKey(window.element)] = window
        }
        var windows: [ManagedWindow] = []

        for app in runningApplications() {
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

            for element in axWindows {
                // Manageability costs seven accessibility round trips to establish. A window
                // already in the model has passed that test once and is kept from here on
                // regardless of the answer, so asking again every tick bought nothing and made
                // the steady-state cost of running scrollini scale with how long it had been up.
                let known = knownByElement[AXElementKey(element)]
                guard known != nil || isManageableWindow(element) else {
                    continue
                }

                let title = axString(element, kAXTitleAttribute) ?? ""
                let appName = app.localizedName ?? "pid \(pid)"
                // Another round trip into the window server, and the answer never changes for
                // the life of a window.
                let windowID = known?.windowID ?? SkyLight.shared.windowID(for: element)
                let window = ManagedWindow(
                    element: element,
                    pid: pid,
                    windowID: windowID,
                    bundleID: app.bundleIdentifier,
                    appName: appName,
                    title: title
                )
                guard behavior(for: window) != .ignore else {
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    func isManageableWindow(_ element: AXUIElement) -> Bool {
        let key = AXElementKey(element)
        if unmanageableWindows.contains(key) {
            return false
        }

        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)

        // Role and subrole are fixed for the life of a window, so failing on either is a final
        // answer and worth remembering. The checks below cost five more round trips, and a
        // palette, popover, or sheet that never becomes a standard window would otherwise pay all
        // of them on every sweep for as long as it exists.
        //
        // A `nil` role is not that answer. An application that has not finished building its
        // accessibility tree answers nothing at all, and caching that would blacklist a perfectly
        // ordinary window for the rest of the session over a few milliseconds of startup timing.
        let roleIsManageable = role == kAXWindowRole
            && !isTransientRole(role)
            && !isTransientSubrole(subrole)
            && (subrole == nil || subrole == kAXStandardWindowSubrole)
        guard roleIsManageable else {
            if role != nil {
                rememberUnmanageableWindow(key)
            }
            return false
        }

        // Minimized state, size, and settability all move while a window is alive: a window that
        // is minimized now can be restored, and an app that has not finished launching can refuse
        // to make position settable and then allow it a moment later. None of these are cached.
        if axBool(element, kAXMinimizedAttribute) == true {
            return false
        }

        guard let frame = axFrame(of: element), frame.width >= 120, frame.height >= 80 else {
            return false
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionError == .success && sizeError == .success && positionSettable.boolValue && sizeSettable.boolValue
    }

    /// Rejections accumulate for as long as the session runs and there is no notification that
    /// says a window scrollini never managed has gone away, so the set is emptied wholesale once
    /// it grows past what any real desktop holds. The cost of being wrong is one expensive sweep.
    func rememberUnmanageableWindow(_ key: AXElementKey) {
        if unmanageableWindows.count >= 512 {
            unmanageableWindows.removeAll(keepingCapacity: true)
        }
        unmanageableWindows.insert(key)
    }

    func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)

        workspace.columns.insert(window, at: insertionIndex)
        workspace.activeColumn = insertionIndex
        workspace.scrollOffset = nil
        if let workspaceIndex = workspaces.firstIndex(where: { $0 === workspace }) {
            setActiveWorkspace(workspaceIndex, rememberPrevious: false)
        }
        ensureTrailingEmptyWorkspace()
        if applyLayout {
            projectLayout(focusActiveWindow: focusNewWindow)
        }
    }

    func targetWorkspace(for window: ManagedWindow) -> Workspace {
        if let oneBased = workspace(for: window) {
            let index = max(0, oneBased - 1)
            ensureWorkspaceExists(index)
            return workspaces[index]
        }

        return activeWorkspaceObject() ?? workspaces[0]
    }

    func ensureWorkspaceExists(_ index: Int) {
        while workspaces.count <= index {
            workspaces.append(Workspace())
        }
    }

    func newWindowInsertionIndex(in workspace: Workspace, for window: ManagedWindow) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        switch openPosition(for: window) {
        case .beforeActive:
            return min(max(workspace.activeColumn, 0), workspace.columns.count)
        case .afterActive:
            return min(max(workspace.activeColumn + 1, 0), workspace.columns.count)
        case .end:
            return workspace.columns.count
        }
    }

    func insertFloatingWindow(_ window: ManagedWindow, applyLayout: Bool = true) {
        if !floatingWindows.contains(where: { $0 === window }) {
            floatingWindows.append(window)
        }
        setWindowAlpha(1, for: window.windowID)
        setFloatingWindowLevel(for: window)
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    func removeWindow(_ window: ManagedWindow) {
        invalidateAppliedLayoutCache(for: window)
        if let index = floatingWindows.firstIndex(where: { $0 === window }) {
            resetFloatingWindowLevel(for: window)
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

    func ensureTrailingEmptyWorkspace() {
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
            for index in stride(from: workspaces.count - 2, through: 0, by: -1) {
                guard index != activeWorkspace, workspaces[index].isEmpty else {
                    continue
                }
                workspaces.remove(at: index)
                if activeWorkspace > index {
                    activeWorkspace -= 1
                }
            }
        }

        activeWorkspace = min(max(activeWorkspace, 0), workspaces.count - 1)
        for workspace in workspaces {
            workspace.clampFocus()
        }
    }
    @discardableResult
    func adoptFocusedWindow(
        pid: pid_t?,
        applyLayout: Bool = true,
        respectFocusSuppression: Bool = false
    ) -> Bool {
        if respectFocusSuppression, shouldSuppressFocusedWindowAdoption {
            return false
        }

        guard let pid else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let focusedElement = asAXUIElement(value) else {
            return false
        }

        if floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        if let loc = location(of: focusedElement) {
            clearTrackpadCamera()
            let workspace = workspaces[loc.workspace]
            let changedFocus = activeWorkspace != loc.workspace || workspace.activeColumn != loc.column
            setActiveWorkspace(loc.workspace)
            workspace.activeColumn = loc.column
            if changedFocus {
                workspace.scrollOffset = nil
            }
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        return false
    }
}
