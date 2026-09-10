#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class LayoutCommandsTests: XCTestCase {

    func testWidthPresetsCycling() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(presetWidthRatios: [0.5, 0.67, 0.8, 1.0]), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.widthPreset(after: 0.5, direction: 1), 0.67)
        XCTAssertEqual(s.widthPreset(after: 1.0, direction: -1), 0.8)
        XCTAssertEqual(s.widthPreset(after: 1.0, direction: 1), 0.5)
        XCTAssertEqual(s.widthPreset(after: 0.5, direction: -1), 1.0)
        XCTAssertEqual(s.widthPreset(after: 0.6, direction: 1), 0.67)
        let s2 = Scrollini()
        s2.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(presetWidthRatios: []), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertNil(s2.widthPreset(after: 0.5, direction: 1))
    }

    func testMaximizeToggle() {
        let s = Scrollini()
        let col = makeWindow(0); col.manualWidthRatio = 1.5
        let ws = Workspace(); ws.columns = [col]; s.workspaces = [ws]; s.activeWorkspace = 0
        XCTAssertTrue(s.toggleMaximizeActiveWidth())
        XCTAssertEqual(s.widthRatio(for: col), 1.0, accuracy: 0.001)
        XCTAssertTrue(s.toggleMaximizeActiveWidth())
        XCTAssertEqual(s.widthRatio(for: col), 1.5, accuracy: 0.001)

        let col2 = makeWindow(1); col2.manualWidthRatio = 1.0
        let ws2 = Workspace(); ws2.columns = [col2]; s.workspaces = [ws2]; s.activeWorkspace = 0
        XCTAssertFalse(s.toggleMaximizeActiveWidth())

        let col3 = makeWindow(2); col3.manualWidthRatio = 0.8
        let ws3 = Workspace(); ws3.columns = [col3]; s.workspaces = [ws3]; s.activeWorkspace = 0
        _ = s.toggleMaximizeActiveWidth()
        _ = s.nudgeActiveWidth(by: -0.1)
        XCTAssertNil(col3.preMaximizeWidthRatio)
    }

    func testNudging() {
        let s = Scrollini()
        XCTAssertEqual(s.nudgedWidthRatio(from: 0.9, by: 0.2), 1.0, accuracy: 0.001)
        XCTAssertEqual(s.nudgedWidthRatio(from: 1.2, by: 0.2), 1.4, accuracy: 0.001)
        XCTAssertEqual(s.nudgedWidthRatio(from: 0.06, by: -0.1), 0.05, accuracy: 0.001)
        XCTAssertEqual(s.nudgedWidthRatio(from: 1.9, by: 0.3), 2.0, accuracy: 0.001)
        let w = makeWindow(5); let ws = Workspace(); ws.columns = [w]; s.workspaces = [ws]; s.activeWorkspace = 0
        w.manualWidthRatio = 0.5
        XCTAssertFalse(s.setWidthRatio(0.502, for: w))
        XCTAssertTrue(s.setWidthRatio(0.6, for: w))
    }

    func testFocusWorkspaceBackAndForth() {
        let s = Scrollini()
        _ = makeScrolliniWithModel().0 // just to have model helper exist
        let (m, _) = makeScrolliniWithModel()
        s.workspaces = m.workspaces
        s.workspaces.append(Workspace())
        s.ensureTrailingEmptyWorkspace()
        s.activeWorkspace = 0
        s.previousWorkspace = s.workspaces[2]
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(workspaceAutoBackAndForth: true), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertTrue(s.focusWorkspace(1))
        XCTAssertEqual(s.activeWorkspace, 2)
    }

    func testMoveColumnAcrossWorkspace() {
        let s = Scrollini()
        let (model, _) = makeScrolliniWithModel()
        s.workspaces = model.workspaces
        s.activeWorkspace = 0
        let before0 = s.workspaces[0].columns.count
        let before1 = s.workspaces[1].columns.count
        XCTAssertTrue(s.moveActiveColumnToWorkspace(zeroBasedIndex: 1))
        XCTAssertEqual(s.workspaces[0].columns.count, before0 - 1)
        XCTAssertEqual(s.workspaces[1].columns.count, before1 + 1)
        XCTAssertFalse(s.moveActiveColumnToWorkspace(zeroBasedIndex: s.activeWorkspace))
    }

    func testSetActiveWorkspaceClamping() {
        let s = Scrollini()
        s.workspaces = [Workspace(), Workspace()]
        XCTAssertFalse(s.setActiveWorkspace(0))
        XCTAssertTrue(s.setActiveWorkspace(1))
        XCTAssertEqual(s.activeWorkspace, 1)
    }

    func testFocusColumnBoundaries() {
        let s = Scrollini()
        let ws = Workspace()
        let w0 = makeWindow(0), w1 = makeWindow(1), w2 = makeWindow(2)
        ws.columns = [w0,w1,w2]; ws.activeColumn = 1
        s.workspaces = [ws]; s.activeWorkspace = 0
        XCTAssertTrue(s.focusColumn(relativeOffset: 1))
        XCTAssertEqual(ws.activeColumn, 2)
        XCTAssertFalse(s.focusColumn(relativeOffset: 1))
    }
}

#endif
