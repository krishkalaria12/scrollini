import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

extension Scrollini {
    func readPersistentLayoutSnapshot() -> PersistentLayoutSnapshot? {
        guard persistLayoutEnabled,
              let data = try? Data(contentsOf: persistentLayoutStateURL),
              let snapshot = try? JSONDecoder().decode(PersistentLayoutSnapshot.self, from: data),
              (1...2).contains(snapshot.version)
        else {
            return nil
        }
        return snapshot
    }

    func writeLayoutSnapshots(viewport: CGRect, timing: LayoutSnapshotTiming) {
        switch timing {
        case .immediate:
            cancelTimer(&snapshotWriteTimer)
            pendingSnapshotViewport = nil
            writeLayoutSnapshotsNow(viewport: viewport)
        case .deferred:
            pendingSnapshotViewport = viewport
            if let snapshotWriteTimer {
                snapshotWriteTimer.schedule(
                    deadline: .now() + .milliseconds(180),
                    leeway: .milliseconds(40)
                )
                return
            }

            snapshotWriteTimer = makeMainTimer(
                deadline: .now() + .milliseconds(180),
                leeway: .milliseconds(40)
            ) { [weak self] in
                self?.flushDeferredLayoutSnapshots()
            }
        }
    }

    func flushDeferredLayoutSnapshots() {
        cancelTimer(&snapshotWriteTimer)

        let viewport = pendingSnapshotViewport ?? currentViewport()
        pendingSnapshotViewport = nil
        writeLayoutSnapshotsNow(viewport: viewport)
    }

    func writeLayoutSnapshotsNow(viewport: CGRect) {
        writeRestoreSnapshot(viewport: viewport)
        writePersistentLayoutSnapshot()
    }

    func writePersistentLayoutSnapshot() {
        guard persistLayoutEnabled else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            lastPersistentLayoutSnapshotData = nil
            return
        }

        let states = workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentWindowState(
                    identity: persistentIdentity(for: window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: window.manualWidthRatio
                )
            }
        }
        guard !states.isEmpty else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            lastPersistentLayoutSnapshotData = nil
            return
        }

        let snapshot = PersistentLayoutSnapshot(
            version: 2,
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            focusedWindow: activeWindow().map(persistentIdentity(for:)),
            windows: states
        )

        do {
            let url = persistentLayoutStateURL
            let data = try JSONEncoder().encode(snapshot)
            if lastPersistentLayoutSnapshotData == data,
               FileManager.default.fileExists(atPath: url.path)
            {
                return
            }

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            lastPersistentLayoutSnapshotData = data
        } catch {
            debugLog("failed to write persistent layout: \(error)")
        }
    }

    @discardableResult
    func applyPersistentLayoutSnapshotIfNeeded() -> Bool {
        guard needsPersistentLayoutRestore else {
            return false
        }

        guard let snapshot = persistentLayoutSnapshot else {
            needsPersistentLayoutRestore = false
            return false
        }

        var usedSnapshotIndices = Set<Int>()
        var placements: [(state: PersistentWindowState, window: ManagedWindow)] = []
        for window in tiledWindows() {
            guard let state = persistentWindowState(for: window, in: snapshot, used: &usedSnapshotIndices) else {
                continue
            }
            window.manualWidthRatio = state.manualWidthRatio
            placements.append((state, window))
        }

        guard !placements.isEmpty else {
            return false
        }
        needsPersistentLayoutRestore = false

        let placedIDs = Set(placements.map { ObjectIdentifier($0.window) })
        let workspaceCount = max(
            workspaces.count,
            (placements.map(\.state.workspace).max() ?? 0) + 1,
            snapshot.activeWorkspace + 1,
            1
        )
        let nextWorkspaces = (0..<workspaceCount).map { _ in Workspace() }

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let targetWorkspace = nextWorkspaces[min(workspaceIndex, nextWorkspaces.count - 1)]
            for window in workspace.columns where !placedIDs.contains(ObjectIdentifier(window)) {
                targetWorkspace.columns.append(window)
            }
        }

        let sortedPlacements = placements.sorted {
            if $0.state.workspace != $1.state.workspace {
                return $0.state.workspace < $1.state.workspace
            }
            return $0.state.column < $1.state.column
        }
        for placement in sortedPlacements {
            let workspaceIndex = min(max(placement.state.workspace, 0), nextWorkspaces.count - 1)
            let workspace = nextWorkspaces[workspaceIndex]
            workspace.columns.insert(placement.window, at: min(max(placement.state.column, 0), workspace.columns.count))
        }

        workspaces = nextWorkspaces
        activeWorkspace = min(max(snapshot.activeWorkspace, 0), workspaces.count - 1)
        for (index, workspace) in workspaces.enumerated() {
            if snapshot.activeColumns.indices.contains(index) {
                workspace.activeColumn = snapshot.activeColumns[index]
            }
            if let scrollOffsets = snapshot.scrollOffsets, scrollOffsets.indices.contains(index) {
                workspace.scrollOffset = scrollOffsets[index]
            } else {
                workspace.scrollOffset = nil
            }
            workspace.clampFocus()
        }
        return true
    }

    func restorePersistentFocusedWindow() -> Bool {
        guard let focusedWindow = persistentLayoutSnapshot?.focusedWindow,
              let location = tiledWindowLocation(matching: focusedWindow)
        else {
            return false
        }

        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        return true
    }

    func persistentWindowState(
        for window: ManagedWindow,
        in snapshot: PersistentLayoutSnapshot,
        used: inout Set<Int>
    ) -> PersistentWindowState? {
        let identity = persistentIdentity(for: window)
        for (index, state) in snapshot.windows.enumerated() where !used.contains(index) && state.identity == identity {
            used.insert(index)
            return state
        }
        return nil
    }

    func persistentIdentity(for window: ManagedWindow) -> PersistentWindowIdentity {
        PersistentWindowIdentity(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    func restoreManagedWindowsForExit() {
        guard restoreOnExit else {
            return
        }

        cancelTimer(&snapshotWriteTimer)
        pendingSnapshotViewport = nil
        clearAppliedLayoutCache()
        let viewport = currentViewport()
        for window in tiledWindows() {
            setWindowAlpha(1, for: window.windowID)
            setWindowLevel(normalWindowLevel, for: window.windowID)
            setAXFrame(viewport, for: window.element)
        }
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
            setWindowLevel(normalWindowLevel, for: window.windowID)
        }
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            lastRestoreSnapshotData = nil
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        let floatingIDs = Array(Set(floatingWindows.compactMap(\.windowID))).sorted()
        guard !ids.isEmpty || !floatingIDs.isEmpty else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            lastRestoreSnapshotData = nil
            return
        }

        let snapshot = RestoreSnapshot(
            windowIDs: ids,
            floatingWindowIDs: floatingIDs,
            viewport: RectSnapshot(viewport)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        if lastRestoreSnapshotData == data,
           FileManager.default.fileExists(atPath: restoreStateURL.path)
        {
            return
        }

        do {
            try data.write(to: restoreStateURL, options: [.atomic])
            lastRestoreSnapshotData = data
        } catch {
            debugLog("failed to write restore snapshot: \(error)")
        }
    }
}
