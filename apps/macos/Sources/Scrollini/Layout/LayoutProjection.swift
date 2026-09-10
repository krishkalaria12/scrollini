import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func seedPresentationFrames(from state: LayoutState) {
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        presentationFrames = Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0.frame) })
    }
    func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        animationDuration: TimeInterval? = nil,
        layoutLockDelay: TimeInterval = 0.08,
        prefocusActiveWindow: Bool = false,
        snapshotTiming: LayoutSnapshotTiming = .immediate,
        verifyActiveLayout: Bool = true,
        suppressManualResizeEvents: Bool = true
    ) {
        let viewport = currentViewport()
        writeLayoutSnapshots(viewport: viewport, timing: animated ? .deferred : snapshotTiming)

        let targetState = captureLayoutState()
        updateStatusItem()
        debugLog("layout workspace=\(targetState.activeWorkspace + 1) tiled=\(tiledWindows().count) floating=\(floatingWindows.count) animated=\(animated)")
        let duration = animationDuration ?? self.animationDuration
        if suppressManualResizeEvents {
            suppressManualResizeNotifications(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        }
        if focusActiveWindow {
            markExpectedFocusedWindow(
                for: activeWindow(),
                duration: (animated ? duration : 0) + max(layoutLockDelay, 0.25) + 0.75
            )
            suppressFocusedWindowAdoption(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        }
        if animated, duration > 0, let previousState {
            animateLayout(
                from: previousState,
                to: targetState,
                viewport: viewport,
                focusActiveWindow: focusActiveWindow,
                prefocusActiveWindow: prefocusActiveWindow,
                duration: duration,
                verifyActiveLayout: verifyActiveLayout
            )
            scheduleColumnMeasurement(after: duration + max(layoutLockDelay, 0.08))
            return
        }

        stopAnimation(clearPresentation: true)
        beginLayoutLock()
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow, forceFocusedFrame: focusActiveWindow)
        if verifyActiveLayout {
            scheduleActiveLayoutVerification(
                focusActiveWindow: focusActiveWindow,
                layoutLockDelay: layoutLockDelay
            )
        }
        restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
        releaseLayoutLock(after: layoutLockDelay)
        scheduleColumnMeasurement(after: max(layoutLockDelay, 0.08) + 0.04)
    }

    func cameraY(for state: LayoutState, viewport: CGRect) -> CGFloat {
        let stateActiveWorkspace = min(max(state.activeWorkspace, 0), max(workspaces.count - 1, 0))
        return state.cameraY ?? CGFloat(stateActiveWorkspace) * viewport.height
    }

    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let cameraY = cameraY(for: state, viewport: viewport)
        let cameraWorkspace = trackpadCameraWorkspaceIndex(cameraY: cameraY, viewport: viewport)
        var layout: [LayoutItem] = []
        layout.reserveCapacity(workspaces.reduce(0) { $0 + $1.columns.count })

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            layout.append(contentsOf: layoutItems(
                for: workspace,
                workspaceIndex: workspaceIndex,
                viewport: viewport,
                state: state,
                cameraY: cameraY,
                cameraWorkspace: cameraWorkspace,
                parkHidden: parkHidden
            ))
        }

        return layout
    }

    /// One workspace's columns, projected. Split out so callers that care about a single window
    /// do not have to lay out every workspace to find it.
    func layoutItems(
        for workspace: Workspace,
        workspaceIndex: Int,
        viewport: CGRect,
        state: LayoutState,
        cameraY: CGFloat,
        cameraWorkspace: Int,
        parkHidden: Bool
    ) -> [LayoutItem] {
        let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
        let scrollOffset = scrollOffset(in: workspace, workspaceIndex: workspaceIndex, state: state)
        let strip = stripFrames(
            for: workspace,
            viewport: viewport,
            activeColumn: activeColumn,
            scrollOffset: scrollOffset
        )
        let rowOffset = CGFloat(workspaceIndex) * viewport.height - cameraY

        return workspace.columns.enumerated().map { columnIndex, window in
            var projected = strip[columnIndex]
            projected.origin.y += rowOffset
            projected = visualFrame(projected, viewport: viewport)

            let visible = projected.intersects(viewport)
            let frame: CGRect
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

            return LayoutItem(window: window, frame: frame, visible: visible)
        }
    }

    /// Where one window belongs right now. Reached from every window move and resize
    /// notification, which arrive in bursts while an app settles, so it lays out only the
    /// workspace that owns the window instead of the whole model.
    func layoutItem(for window: ManagedWindow, viewport: CGRect, state: LayoutState, parkHidden: Bool) -> LayoutItem? {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.columns.contains { $0 === window }
        }) else {
            return nil
        }

        let cameraY = cameraY(for: state, viewport: viewport)
        let items = layoutItems(
            for: workspaces[workspaceIndex],
            workspaceIndex: workspaceIndex,
            viewport: viewport,
            state: state,
            cameraY: cameraY,
            cameraWorkspace: trackpadCameraWorkspaceIndex(cameraY: cameraY, viewport: viewport),
            parkHidden: parkHidden
        )
        return items.first { $0.window === window }
    }

    func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    func trackpadCameraWorkspaceIndex(cameraY: CGFloat, viewport: CGRect) -> Int {
        guard viewport.height > 0, !workspaces.isEmpty else {
            return 0
        }

        return min(max(Int(round(cameraY / viewport.height)), 0), workspaces.count - 1)
    }

    func applyLayout(
        _ layout: [LayoutItem],
        focusActiveWindow: Bool,
        verifyFocus: Bool = true,
        focusDelay: TimeInterval = 0,
        forceFocusedFrame: Bool = false
    ) {
        let focusedWindow = focusActiveWindow ? activeWindow() : nil
        if let focusedWindow, let focusedItem = layout.first(where: { $0.window === focusedWindow }) {
            applyFrame(focusedItem.frame, to: focusedWindow, force: forceFocusedFrame)
            setWindowAlpha(1, for: focusedWindow.windowID)
        }

        for item in layout where item.visible {
            if let focusedWindow, item.window === focusedWindow {
                continue
            }
            applyFrame(item.frame, to: item.window)
            setWindowAlpha(1, for: item.window.windowID)
        }

        for item in layout where !item.visible {
            applyFrame(item.frame, to: item.window)
            setWindowAlpha(0, for: item.window.windowID)
        }

        if let focusedWindow {
            requestFocus(focusedWindow, verify: verifyFocus, delay: focusDelay)
        }
    }

    func restoreFloatingVisibility(raise: Bool = false, deferred: Bool = false) {
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
            setFloatingWindowLevel(for: window)
            if raise {
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            }
        }

        if raise && deferred {
            scheduleFloatingWindowRaise()
        }
    }

    func setFloatingWindowLevel(for window: ManagedWindow) {
        setWindowLevel(floatingWindowLevel, for: window.windowID)
    }

    func resetFloatingWindowLevel(for window: ManagedWindow) {
        setWindowLevel(normalWindowLevel, for: window.windowID)
    }

    func scheduleFloatingWindowRaise() {
        guard !floatingWindows.isEmpty else {
            return
        }

        floatingRaiseGeneration &+= 1
        let generation = floatingRaiseGeneration
        for delay in [0.04, 0.16, 0.34] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      generation == floatingRaiseGeneration
                else {
                    return
                }
                restoreFloatingVisibility(raise: true)
            }
        }
    }
    func setWindowAlpha(_ alpha: Float, for windowID: UInt32?) {
        guard hideMethod == .skyLightAlpha else {
            return
        }
        if let windowID {
            if let previous = appliedAlphas[windowID], abs(previous - alpha) < 0.001 {
                return
            }
            SkyLight.shared.setAlpha(alpha, for: windowID)
            appliedAlphas[windowID] = alpha
            return
        }
        SkyLight.shared.setAlpha(alpha, for: windowID)
    }

    func setWindowLevel(_ level: Int32, for windowID: UInt32?) {
        guard let windowID, SkyLight.shared.canSetWindowLevel else {
            return
        }

        if appliedWindowLevels[windowID] == level {
            return
        }

        guard SkyLight.shared.setLevel(level, for: windowID) else {
            return
        }

        if level == normalWindowLevel {
            appliedWindowLevels.removeValue(forKey: windowID)
        } else {
            appliedWindowLevels[windowID] = level
        }
    }

    func clearAppliedLayoutCache() {
        appliedFrames.removeAll()
        appliedAlphas.removeAll()
        appliedWindowLevels.removeAll()
    }

    func invalidateAppliedLayoutCache(for window: ManagedWindow) {
        appliedFrames.removeValue(forKey: ObjectIdentifier(window))
        if let windowID = window.windowID {
            appliedAlphas.removeValue(forKey: windowID)
            appliedWindowLevels.removeValue(forKey: windowID)
        }
    }

    func invalidateAppliedLayoutCache(for element: AXUIElement) {
        guard let window = allWindows().first(where: { sameWindow($0.element, element) }) else {
            return
        }
        invalidateAppliedLayoutCache(for: window)
    }

    func pruneAppliedLayoutCache() {
        let windows = allWindows()
        let liveWindowIDs = Set(windows.map(ObjectIdentifier.init))
        appliedFrames = appliedFrames.filter { liveWindowIDs.contains($0.key) }

        let liveSkyLightIDs = Set(windows.compactMap(\.windowID))
        appliedAlphas = appliedAlphas.filter { liveSkyLightIDs.contains($0.key) }
        appliedWindowLevels = appliedWindowLevels.filter { liveSkyLightIDs.contains($0.key) }
    }
    func insetViewport(_ viewport: CGRect, by inset: CGFloat) -> CGRect {
        guard inset > 0 else {
            return viewport
        }

        let safeInset = min(inset, viewport.width / 3, viewport.height / 3)
        return viewport.insetBy(dx: safeInset, dy: safeInset)
    }
    /// The working area scrollini lays out on, held briefly so one burst of work sees one
    /// viewport. Roughly twenty call sites ask for this, several of them per animation frame and
    /// per pointer move, and a layout pass that read two different answers halfway through would
    /// place its columns against two different rectangles. The window keeps staleness far below
    /// anything a person can see, and a display change clears it outright.
    func currentViewport() -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()
        if let cachedViewport, now - cachedViewportAt < viewportCacheDuration {
            return cachedViewport
        }

        let viewport = computeViewport()
        cachedViewport = viewport
        cachedViewportAt = now
        return viewport
    }

    func invalidateViewportCache() {
        cachedViewport = nil
        cachedViewportAt = 0
    }

    /// Deliberately the primary screen rather than `NSScreen.main`. `main` is whichever screen
    /// holds the key window, so opening the settings window on a second display used to drag the
    /// whole tiled layout across with it, and closing it dragged everything back. scrollini is a
    /// single-display manager by design, and which display it owns must not depend on where some
    /// window happens to be sitting.
    func computeViewport() -> CGRect {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            return insetViewport(CGDisplayBounds(CGMainDisplayID()), by: outerGap)
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        let viewport = CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
        return insetViewport(viewport, by: outerGap)
    }
}
