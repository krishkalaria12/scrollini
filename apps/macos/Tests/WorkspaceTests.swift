#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class WorkspaceTests: XCTestCase {

    func testEnsureTrailingEmptyWorkspaceAddsOne() {
        let s = Scrollini()
        s.workspaces = [Workspace()]
        s.workspaces[0].columns = [makeWindow(0)]
        s.ensureTrailingEmptyWorkspace()
        XCTAssertEqual(s.workspaces.count, 2)
        XCTAssertTrue(s.workspaces.last!.isEmpty)
        XCTAssertFalse(s.workspaces.dropLast().contains(where: \.isEmpty))
    }

    func testEmptyMiddleCollapsesAndActiveFollows() {
        let (s, _) = makeScrolliniWithModel()
        s.ensureTrailingEmptyWorkspace()
        s.workspaces[1].columns.removeAll()
        s.activeWorkspace = 2
        s.ensureTrailingEmptyWorkspace()
        XCTAssertEqual(s.workspaces.count, 3)
        XCTAssertEqual(s.activeWorkspace, 1)
        XCTAssertEqual(s.activeWorkspaceObject()?.columns.count, 4)
    }

    func testSeedsWhenEmpty() {
        let s = Scrollini()
        s.workspaces = []
        s.activeWorkspace = 5
        s.ensureTrailingEmptyWorkspace()
        XCTAssertEqual(s.workspaces.count, 1)
        XCTAssertEqual(s.activeWorkspace, 0)
    }

    func testClampFocus() {
        let ws = Workspace()
        ws.columns = [makeWindow(0), makeWindow(1)]
        ws.activeColumn = 10
        ws.clampFocus()
        XCTAssertEqual(ws.activeColumn, 1)
        ws.columns = []
        ws.clampFocus()
        XCTAssertEqual(ws.activeColumn, 0)
        XCTAssertNil(ws.scrollOffset)
    }

    func testNewWindowInsertionIndex() {
        let s = Scrollini()
        let ws = Workspace()
        ws.columns = [makeWindow(0), makeWindow(1)]
        ws.activeColumn = 0
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(newWindowPosition: .afterActive), sourceURL: nil, sourceModificationDate: nil)
        let w = makeWindow(99)
        XCTAssertEqual(s.newWindowInsertionIndex(in: ws, for: w), 1)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(newWindowPosition: .beforeActive), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.newWindowInsertionIndex(in: ws, for: w), 0)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(newWindowPosition: .end), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.newWindowInsertionIndex(in: ws, for: w), 2)
        let empty = Workspace()
        XCTAssertEqual(s.newWindowInsertionIndex(in: empty, for: w), 0)
    }
}

#endif
