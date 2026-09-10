import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    /// Asks every column in the active workspace what width it actually ended up with, once the
    /// layout has had time to land. Apps are free to refuse the width scrollini requests, and the strip
    /// can only stay tight if it packs against what they granted.
    func scheduleColumnMeasurement(after delay: TimeInterval) {
        columnMeasurementGeneration &+= 1
        let generation = columnMeasurementGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.02)) { [weak self] in
            self?.measureColumnWidths(generation: generation)
        }
    }

    func measureColumnWidths(generation: UInt64) {
        guard generation == columnMeasurementGeneration,
              animationTimer == nil,
              !isApplyingLayout,
              manualResizeElement == nil,
              trackpadRenderTimer == nil,
              trackpadMomentumTimer == nil,
              let workspace = activeWorkspaceObject()
        else {
            return
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return
        }

        let strip = stripFrames(
            for: workspace,
            viewport: viewport,
            activeColumn: workspace.activeColumn,
            scrollOffset: workspace.scrollOffset
        )

        var changed = false
        for (columnIndex, window) in workspace.columns.enumerated() {
            let requested = requestedWidth(for: window, viewport: viewport)
            // Every AX read is an IPC round trip, so keep the steady-state cost to the handful of
            // columns actually on screen. An off-screen column still gets measured the first time
            // it is asked for a given width, and again as soon as it scrolls into view.
            let isVisible = strip.indices.contains(columnIndex) && strip[columnIndex].intersects(viewport)
            let isUnmeasured = window.measuredForWidth.map { abs($0 - requested) >= 1 } ?? true
            guard isVisible || isUnmeasured else {
                continue
            }

            guard let frame = axFrame(of: window.element), frame.width > 0 else {
                continue
            }
            changed = recordMeasuredWidth(frame.width, requested: requested, for: window) || changed
        }

        guard changed else {
            return
        }

        // Re-packing does not change what any column asks for, so the follow-up measurement this
        // schedules finds every width already recorded and stops there.
        debugLog("re-packing strip against measured column widths")
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02, verifyActiveLayout: false)
    }

    func activeWindowFrameMatchesLayout(_ window: ManagedWindow) -> Bool {
        guard let expectedItem = currentLayoutItem(for: window), expectedItem.visible else {
            return true
        }
        guard let actualFrame = axFrame(of: window.element) else {
            return true
        }

        if framesApproximatelyEqual(actualFrame, expectedItem.frame, tolerance: 2) {
            return true
        }

        // The window went where it was told but not to the size it was told. Re-sending the same
        // frame would only get clamped again, so record what the app granted and let the
        // measurement pass re-pack the strip around it.
        let positionMatches = abs(actualFrame.minX - expectedItem.frame.minX) <= 2
            && abs(actualFrame.minY - expectedItem.frame.minY) <= 2
        if positionMatches {
            let viewport = currentViewport()
            if viewport.width > 0, actualFrame.width > 0 {
                let requested = requestedWidth(for: window, viewport: viewport)
                _ = recordMeasuredWidth(actualFrame.width, requested: requested, for: window)
            }
            return true
        }

        return false
    }

    func scheduleActiveLayoutVerification(
        focusActiveWindow: Bool,
        layoutLockDelay: TimeInterval = 0.08
    ) {
        layoutVerificationGeneration &+= 1
        guard !focusActiveWindow, layoutLockDelay > 0 else {
            return
        }
        guard let window = activeWindow() else {
            return
        }

        let generation = layoutVerificationGeneration
        let windowID = ObjectIdentifier(window)
        for delay in [0.06, 0.16, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyActiveLayout(
                    windowID: windowID,
                    generation: generation,
                    focusActiveWindow: focusActiveWindow
                )
            }
        }
    }

    func verifyActiveLayout(
        windowID: ObjectIdentifier,
        generation: UInt64,
        focusActiveWindow: Bool
    ) {
        guard generation == layoutVerificationGeneration,
              animationTimer == nil,
              let window = activeWindow(),
              ObjectIdentifier(window) == windowID
        else {
            return
        }

        guard activeWindowFrameMatchesLayout(window) else {
            debugLog("forcing active layout correction for \(window.appName)")
            forceActiveWindowLayout(window, focusActiveWindow: focusActiveWindow)
            return
        }
    }

    func forceActiveWindowLayout(_ window: ManagedWindow, focusActiveWindow: Bool) {
        guard let expectedItem = currentLayoutItem(for: window), expectedItem.visible else {
            return
        }

        applyFrame(expectedItem.frame, to: window, force: true)
        setWindowAlpha(1, for: window.windowID)
        if focusActiveWindow {
            requestFocus(window, verify: false, delay: 0)
        }
    }

    func systemFrameMatchesCurrentLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let expectedItem = currentLayoutItem(for: window),
              let actualFrame = axFrame(of: element),
              framesApproximatelyEqual(actualFrame, expectedItem.frame, tolerance: 2)
        else {
            return false
        }

        appliedFrames[ObjectIdentifier(window)] = actualFrame
        return true
    }

    func currentLayoutItem(for window: ManagedWindow) -> LayoutItem? {
        layoutItem(
            for: window,
            viewport: currentViewport(),
            state: captureLayoutState(),
            parkHidden: true
        )
    }

    func framesApproximatelyEqual(_ left: CGRect, _ right: CGRect, tolerance: CGFloat) -> Bool {
        abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    func reapplyCurrentLayout(focusActiveWindow: Bool, verifyFocus: Bool) {
        clearAppliedLayoutCache()
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: captureLayoutState(), parkHidden: true)
        applyLayout(
            layout,
            focusActiveWindow: focusActiveWindow,
            verifyFocus: verifyFocus,
            forceFocusedFrame: focusActiveWindow
        )
        restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
    }
}
