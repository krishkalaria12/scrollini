import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    /// Frames leave `stripFrames` with gaps already reserved around them, so what the strip
    /// computes is what the window gets. Kept as a seam for callers that reason about a column's
    /// on-screen rectangle.
    func visualFrame(_ frame: CGRect, viewport: CGRect) -> CGRect {
        frame
    }
    func stripFrames(
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
        // Column origins live in a gap-free virtual strip, so the leading outer gap is added here
        // once rather than being baked into every origin.
        // The viewport already excludes the menu bar and Dock. Gaps separate columns
        // horizontally; applying them vertically wastes working height.
        let columnHeight = max(1, viewport.height)
        return workspace.columns.indices.map { index in
            CGRect(
                x: viewport.minX + innerGap + metrics.origins[index] - scrollOffset,
                y: viewport.minY,
                width: metrics.widths[index],
                height: columnHeight
            )
        }
    }

    func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
        var virtualX: CGFloat = 0
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []

        for window in workspace.columns {
            origins.append(virtualX)
            let width = layoutWidth(for: window, viewport: viewport)
            widths.append(width)
            virtualX += width + innerGap
        }

        return (origins, widths)
    }

    /// Width this column asks the app for, using niri's proportional sizing: a ratio of `1.0` fills
    /// the viewport minus one gap on each side, and two `0.5` columns tile it exactly, gaps
    /// included.
    func requestedWidth(for window: ManagedWindow, viewport: CGRect) -> CGFloat {
        max(1, (viewport.width - innerGap) * widthRatio(for: window) - innerGap)
    }

    /// Width the strip actually packs against. Apps with minimum sizes or character-cell width
    /// increments cannot always take the width they are asked for, and laying the neighbours out
    /// against the *requested* width leaves a visible band of empty desktop next to every such
    /// window. Packing against the granted width closes those holes, the same way niri packs
    /// columns against each tile's real size instead of its configured proportion.
    func layoutWidth(for window: ManagedWindow, viewport: CGRect) -> CGFloat {
        let requested = requestedWidth(for: window, viewport: viewport)
        guard let measuredWidth = window.measuredWidth,
              let measuredForWidth = window.measuredForWidth,
              abs(measuredForWidth - requested) < 1
        else {
            return requested
        }
        return max(1, measuredWidth)
    }

    /// Records what macOS granted for a window that was just asked to take `requested` width.
    /// `measuredForWidth` is always stamped, including when the app took the width it was offered,
    /// so a well-behaved window is not re-measured on every layout; a `nil` `measuredWidth` is the
    /// recorded answer "this one does not clamp".
    func recordMeasuredWidth(_ granted: CGFloat, requested: CGFloat, for window: ManagedWindow) -> Bool {
        let clamped: CGFloat? = abs(granted - requested) >= 1 ? granted : nil
        let changed: Bool
        switch (window.measuredWidth, clamped) {
        case (nil, nil):
            changed = false
        case let (previous?, clamped?):
            changed = abs(previous - clamped) >= 1
        default:
            changed = true
        }

        window.measuredWidth = clamped
        window.measuredForWidth = requested
        return changed
    }

    func horizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        if let scrollOffset = workspace.scrollOffset {
            return min(max(scrollOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let activeColumn = min(max(workspace.activeColumn, 0), max(workspace.columns.count - 1, 0))
        return defaultScrollOffset(metrics: metrics, activeColumn: activeColumn, viewport: viewport)
    }

    func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let contentWidth = (zip(metrics.origins, metrics.widths).map { $0.0 + $0.1 }.max() ?? viewport.width)
            + innerGap * 2
        let lastColumnOffset = defaultScrollOffset(
            metrics: metrics,
            activeColumn: workspace.columns.count - 1,
            viewport: viewport
        )
        return max(0, contentWidth - viewport.width, lastColumnOffset)
    }

    func defaultScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect
    ) -> CGFloat {
        guard metrics.origins.indices.contains(activeColumn),
              metrics.widths.indices.contains(activeColumn)
        else {
            return 0
        }

        switch focusAlignment {
        case .left:
            return metrics.origins[activeColumn]
        case .smart where activeColumn == 0:
            return metrics.origins.indices.contains(activeColumn) ? metrics.origins[activeColumn] : 0
        case .smart, .center:
            // Strip frames render at `viewport.minX + innerGap + origin - offset`, so centring has
            // to cancel that leading gap out.
            let activeCenter = metrics.origins[activeColumn] + metrics.widths[activeColumn] / 2
            return max(0, activeCenter + innerGap - viewport.width / 2)
        }
    }

    func parkedFrame(for window: ManagedWindow, viewport: CGRect, beforeActive: Bool) -> CGRect {
        let width = layoutWidth(for: window, viewport: viewport)
        let height = max(1, viewport.height)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: height)

        // The viewport already excludes the outer gap. Parking against that inset edge exposes
        // the outer gap plus the requested sliver, so hidden columns remain visibly stacked over
        // the nearest column. Recover the real display edge before placing the sliver.
        let displayMinX = viewport.minX - outerGap
        let displayMaxX = viewport.maxX + outerGap
        frame.origin.x = beforeActive
            ? displayMinX - width + parkedSliverWidth
            : displayMaxX - parkedSliverWidth
        return frame
    }
}
