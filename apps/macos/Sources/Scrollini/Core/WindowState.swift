import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func activeWorkspaceObject() -> Workspace? {
        guard workspaces.indices.contains(activeWorkspace) else {
            return nil
        }
        return workspaces[activeWorkspace]
    }

    func captureLayoutState() -> LayoutState {
        LayoutState(
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            cameraY: trackpadCameraY
        )
    }
    func activeWindow() -> ManagedWindow? {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return nil
        }
        workspace.clampFocus()
        return workspace.columns[workspace.activeColumn]
    }

    func allWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns) + floatingWindows
    }

    func tiledWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns)
    }
    func location(of element: AXUIElement) -> (workspace: Int, column: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() where sameWindow(window.element, element) {
                return (workspaceIndex, columnIndex)
            }
        }
        return nil
    }

    func tiledWindowLocation(
        for element: AXUIElement
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    func tiledWindowLocation(
        matching identity: PersistentWindowIdentity
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    func tiledWindow(for element: AXUIElement) -> ManagedWindow? {
        tiledWindowLocation(for: element)?.window
    }
}
