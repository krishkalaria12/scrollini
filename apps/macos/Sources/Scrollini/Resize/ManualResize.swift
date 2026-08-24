import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    /// Inverse of `requestedWidth`, so a width read back off a window maps to the ratio that would
    /// have asked for it.
    func widthRatio(forWidth width: CGFloat, viewport: CGRect) -> CGFloat {
        let usable = viewport.width - innerGap
        guard usable > 0 else {
            return config.defaultWidthRatio.clampedWidthRatio
        }
        return ((width + innerGap) / usable).clampedManualWidthRatio
    }

    /// A resize is only the user's if a mouse button is down for it. macOS also reports a resize
    /// when an app *refuses* the size scrollini asked for — minimum sizes, character-cell increments,
    /// a window restoring its own remembered geometry. Treating those as intent is what let every
    /// window slowly drift to its own arbitrary width and persist it across restarts.
    func windowResizeIsUserDriven() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    func updateManualWidthRatio(for element: AXUIElement, userDriven: Bool) -> Bool {
        guard let location = tiledWindowLocation(for: element),
              let frame = axFrame(of: element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        guard location.workspaceIndex == activeWorkspace else {
            return false
        }

        let window = location.window
        guard userDriven else {
            // The app pushed back on the width it was given. Remember what it settled on so the
            // strip packs against it, but leave the column's configured width alone.
            let requested = requestedWidth(for: window, viewport: viewport)
            return recordMeasuredWidth(frame.width, requested: requested, for: window)
        }

        let ratio = widthRatio(forWidth: frame.width, viewport: viewport)
        let previousRatio = window.manualWidthRatio
        let oldScrollOffset = location.workspace.scrollOffset
        window.manualWidthRatio = ratio
        // The drag *is* the new request, so any width the app clamped us to before is stale, and
        // so is any width to un-maximize back to.
        window.measuredWidth = nil
        window.measuredForWidth = nil
        window.preMaximizeWidthRatio = nil

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin + innerGap - (frame.minX - viewport.minX)

        location.workspace.scrollOffset = newScrollOffset
        location.workspace.activeColumn = location.columnIndex
        presentationFrames[ObjectIdentifier(window)] = frame

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
        {
            return false
        }

        return true
    }

    func beginOrContinueManualResize(for element: AXUIElement) {
        cancelHoverFocus()
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility(raise: true)
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        // An app resizing itself is not a drag, so it must not take over the resize path: doing so
        // would suspend trackpad navigation and hover focus for every window that merely clamps
        // the width it was handed.
        guard windowResizeIsUserDriven() else {
            if updateManualWidthRatio(for: element, userDriven: false) {
                projectLayout(
                    focusActiveWindow: false,
                    layoutLockDelay: 0.02,
                    snapshotTiming: .deferred,
                    verifyActiveLayout: false
                )
            }
            return
        }

        manualResizeElement = element
        cancelTimer(&manualResizeEndTimer)
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element, userDriven: true) {
            projectLayout(
                focusActiveWindow: false,
                layoutLockDelay: 0,
                snapshotTiming: .deferred,
                suppressManualResizeEvents: false
            )
        }

        scheduleManualResizeEnd(for: element)
    }

    var manualResizeNotificationsSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < manualResizeSuppressedUntil
    }

    func suppressManualResizeNotifications(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }
        manualResizeSuppressedUntil = max(manualResizeSuppressedUntil, CFAbsoluteTimeGetCurrent() + duration)
    }

    func scheduleManualResizeEnd(for element: AXUIElement) {
        manualResizeEndTimer = makeMainTimer(
            deadline: .now() + .milliseconds(140),
            leeway: .milliseconds(20)
        ) { [weak self] in
            guard let self else {
                return
            }

            cancelTimer(&manualResizeEndTimer)

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                // Reached only from the user-driven branch above, and the drag may already have
                // ended by now, so the final width still counts as intent.
                _ = updateManualWidthRatio(for: element, userDriven: true)
                projectLayout(
                    focusActiveWindow: false,
                    layoutLockDelay: 0.02,
                    suppressManualResizeEvents: false
                )
                manualResizeElement = nil
            }
        }
    }

    func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeElement.map { sameWindow($0, element) } ?? false
    }

    func frameWidthDiffersFromLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame = axFrame(of: element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        // Compared against the width the strip is actually laying this column out at, so a window
        // an app has clamped does not read as a fresh resize on every move notification.
        return abs(frame.width - layoutWidth(for: window, viewport: viewport)) >= 1
    }
}
