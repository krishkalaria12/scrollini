import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func handleMouseMoved(_ event: CGEvent) {
        guard hoverFocusEnabled,
              !transientSystemWindowIsActive(),
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

        // Resolved once. This runs inside the event tap callback on every pointer move, and
        // `hoverFocusTarget(at:)` projects the whole layout to answer, so asking it twice was
        // doubling the cost of the hottest path in the program.
        guard let target = hoverFocusTarget(at: event.location) else {
            hoverFocusRequiresRearm = false
            cancelHoverFocus()
            return
        }

        // Focus already moved to whatever is under the pointer. Until the pointer leaves every
        // hover target, further moves must not keep re-triggering it.
        guard !hoverFocusRequiresRearm else {
            cancelHoverFocus()
            return
        }

        if target.immediate {
            performHoverFocus(window: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        } else {
            scheduleHoverFocus(for: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        }
    }
    func hoverFocusTarget(
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
        if hoverFocusMode == .edgeOrVisible,
           let edgeTarget = hoverFocusEdgeTarget(
                point: point,
                workspace: workspace,
                workspaceIndex: activeWorkspace,
                state: state,
                viewport: viewport
           )
        {
            return edgeTarget
        }

        for item in layout where item.visible && item.frame.contains(point) {
            guard hoverToFocusAllowed(for: item.window) else {
                continue
            }
            guard let loc = location(of: item.window.element), loc.workspace == activeWorkspace else {
                continue
            }
            if loc.column == workspace.activeColumn {
                return nil
            }
            let immediate = hoverFocusMode == .edgeOrVisible
                && hoverFocusEdgeTrigger(
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

    func hoverFocusEdgeTarget(
        point: CGPoint,
        workspace: Workspace,
        workspaceIndex: Int,
        state: LayoutState,
        viewport: CGRect
    ) -> (window: ManagedWindow, workspaceIndex: Int, columnIndex: Int, immediate: Bool)? {
        let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
        let targetColumn: Int
        if point.x >= viewport.maxX - hoverFocusEdgeTriggerWidth {
            targetColumn = activeColumn + 1
        } else if point.x <= viewport.minX + hoverFocusEdgeTriggerWidth {
            targetColumn = activeColumn - 1
        } else {
            return nil
        }

        guard workspace.columns.indices.contains(targetColumn) else {
            return nil
        }

        let window = workspace.columns[targetColumn]
        guard hoverToFocusAllowed(for: window) else {
            return nil
        }

        return (window, workspaceIndex, targetColumn, true)
    }

    func viewportContains(_ point: CGPoint, viewport: CGRect) -> Bool {
        point.x >= viewport.minX
            && point.x <= viewport.maxX
            && point.y >= viewport.minY
            && point.y <= viewport.maxY
    }
    func hoverFocusEdgeTrigger(
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

    func hoverFocusCanScroll(
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

    func scheduleHoverFocus(for window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        let id = ObjectIdentifier(window)
        if hoverFocusTarget == id {
            return
        }

        cancelHoverFocus()
        hoverFocusTarget = id

        hoverFocusTimer = makeMainTimer(
            deadline: .now() + hoverFocusDelay,
            leeway: .milliseconds(20)
        ) { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            performHoverFocus(window: window, workspaceIndex: workspaceIndex, columnIndex: columnIndex)
        }
    }

    func performHoverFocus(window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        cancelTimer(&hoverFocusTimer)
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
        projectLayout(
            focusActiveWindow: true,
            animated: previousState != newState,
            from: previousState,
            animationDuration: hoverFocusAnimationDuration
        )
    }

    func cancelHoverFocus() {
        cancelTimer(&hoverFocusTimer)
        hoverFocusTarget = nil
    }
}
