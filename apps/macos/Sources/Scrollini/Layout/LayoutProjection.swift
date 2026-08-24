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

    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
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
                projected = visualFrame(projected, viewport: viewport)

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
    func currentViewport() -> CGRect {
        guard let screen = NSScreen.main else {
            return insetViewport(CGDisplayBounds(CGMainDisplayID()), by: outerGap)
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        let viewport = CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
        return insetViewport(viewport, by: outerGap)
    }
}
