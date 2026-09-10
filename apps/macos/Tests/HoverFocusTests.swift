#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class HoverFocusTests: XCTestCase {

    func testHoverStaysOnActiveWorkspace() {
        let (s, _) = makeScrolliniWithModel()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .edgeOrVisible), sourceURL: nil, sourceModificationDate: nil)
        let activeIDs = Set(s.workspaces[0].columns.map(ObjectIdentifier.init))
        var strays = 0, selfTargets = 0, found = 0
        for x in stride(from: testViewport.minX, through: testViewport.maxX, by: 13) {
            for y in stride(from: testViewport.minY, through: testViewport.maxY, by: 97) {
                s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
                guard let t = s.hoverFocusTarget(at: CGPoint(x: x, y: y)) else { continue }
                found += 1
                if t.workspaceIndex != s.activeWorkspace { strays += 1 }
                if !activeIDs.contains(ObjectIdentifier(t.window)) { strays += 1 }
                if t.columnIndex == s.workspaces[0].activeColumn { selfTargets += 1 }
            }
        }
        XCTAssertGreaterThan(found, 0)
        XCTAssertEqual(strays, 0)
        XCTAssertEqual(selfTargets, 0)
    }

    func testEdgeTriggerAndViewportContains() {
        let (s, _) = makeScrolliniWithModel()
        s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusEdgeTriggerWidth: 8, hoverFocusMode: .edgeOrVisible), sourceURL: nil, sourceModificationDate: nil)
        let ws = s.workspaces[0]
        let active = ws.activeColumn
        XCTAssertTrue(s.hoverFocusEdgeTrigger(targetColumn: active+1, activeColumn: active, point: CGPoint(x: testViewport.maxX - 4, y: testViewport.midY), viewport: testViewport))
        XCTAssertTrue(s.hoverFocusEdgeTrigger(targetColumn: active-1, activeColumn: active, point: CGPoint(x: testViewport.minX + 4, y: testViewport.midY), viewport: testViewport))
        XCTAssertFalse(s.hoverFocusEdgeTrigger(targetColumn: active, activeColumn: active, point: CGPoint(x: testViewport.maxX - 4, y: testViewport.midY), viewport: testViewport))
        XCTAssertTrue(s.viewportContains(CGPoint(x: testViewport.midX, y: testViewport.midY), viewport: testViewport))
        XCTAssertFalse(s.viewportContains(CGPoint(x: testViewport.maxX + 10, y: testViewport.midY), viewport: testViewport))
    }

    func testCanScrollNeedsDepth() {
        let s = Scrollini()
        let a = makeWindow(910); a.manualWidthRatio = 0.5
        let b = makeWindow(911); b.manualWidthRatio = 0.5
        let ws = Workspace(); ws.columns = [a,b]; ws.activeColumn = 0
        s.workspaces = [ws]; s.activeWorkspace = 0
        var cfg = ScrolliniConfig(); cfg.innerGap = 12; cfg.hoverFocusMaxScrollRatio = 0.15; cfg.hoverFocusRequiresVisibleRatio = 0.15
        s.loadedConfig = LoadedScrolliniConfig(config: cfg, sourceURL: nil, sourceModificationDate: nil)
        s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let state = s.captureLayoutState()
        let camY = s.cameraY(for: state, viewport: testViewport)
        let items = s.layoutItems(for: ws, workspaceIndex: 0, viewport: testViewport, state: state, cameraY: camY, cameraWorkspace: 0, parkHidden: false)
        let targetFrame = items[1].frame
        let visible = targetFrame.intersection(testViewport)
        XCTAssertFalse(visible.isNull)
        let required = testViewport.width * s.hoverFocusMaxScrollRatio
        let good = CGPoint(x: visible.minX + required + 10, y: testViewport.midY)
        let bad = CGPoint(x: visible.minX + 1, y: testViewport.midY)
        XCTAssertTrue(s.hoverFocusCanScroll(toColumn: 1, in: ws, workspaceIndex: 0, state: state, viewport: testViewport, targetFrame: targetFrame, point: good))
        XCTAssertFalse(s.hoverFocusCanScroll(toColumn: 1, in: ws, workspaceIndex: 0, state: state, viewport: testViewport, targetFrame: targetFrame, point: bad))
        XCTAssertFalse(s.hoverFocusCanScroll(toColumn: 1, in: ws, workspaceIndex: 0, state: state, viewport: CGRect(x: 0,y: 0,width: 0,height: 1000), targetFrame: targetFrame, point: good))
    }

    func testHoverModeOff() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .off), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertFalse(s.hoverFocusEnabled)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .visibleOnly), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertTrue(s.hoverFocusEnabled)
    }
}

#endif
