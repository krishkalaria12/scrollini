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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                  !reconcileExpectedFocusChange(pid: app.processIdentifier),
                  !shouldSuppressFocusedWindowAdoption
            else {
                return
            }
            rescanWindows(adoptFocused: false)
            adoptFocusedWindow(pid: app.processIdentifier, respectFocusSuppression: true)
        }
        adoptFocusedWindow(pid: app.processIdentifier, respectFocusSuppression: true)
    }

    @objc func applicationLaunched(_ notification: Notification) {
        scheduleRescan(after: 0.4, adoptFocused: true)
    }

    @objc func applicationTerminated(_ notification: Notification) {
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
    func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        let discovered = discoverWindows()
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
        let knownWindows = allWindows()
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

            for element in axWindows where isManageableWindow(element) || isKnownWindow(element, in: knownWindows) {
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
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    func isManageableWindow(_ element: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)

        guard role == kAXWindowRole else {
            return false
        }

        guard !isTransientRole(role), !isTransientSubrole(subrole) else {
            return false
        }

        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

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

    func isKnownWindow(_ element: AXUIElement, in knownWindows: [ManagedWindow]) -> Bool {
        knownWindows.contains { sameWindow($0.element, element) }
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
        if let oneBased = rule(for: window)?.workspace {
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

        switch rule(for: window)?.openPosition ?? newWindowPosition {
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
        guard error == .success, let focused = value else {
            return false
        }

        let focusedElement = focused as! AXUIElement
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
