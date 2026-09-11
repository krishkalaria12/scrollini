#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class StripLayoutTests: XCTestCase {

    func testProportionalSizingTwoHalfTileExactly() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(innerGap: 12), sourceURL: nil, sourceModificationDate: nil)
        let l = makeWindow(1); l.manualWidthRatio = 0.5
        let r = makeWindow(2); r.manualWidthRatio = 0.5
        let ws = Workspace(); ws.columns = [l, r]
        let m = s.stripMetrics(for: ws, viewport: testViewport)
        let occupied = m.widths[0] + s.innerGap + m.widths[1] + s.innerGap * 2
        XCTAssertEqual(occupied, testViewport.width, accuracy: 0.01)
    }

    func testFullWidthFillsMinusGaps() {
        let s = Scrollini()
        let w = makeWindow(10); w.manualWidthRatio = 1.0
        XCTAssertEqual(s.requestedWidth(for: w, viewport: testViewport), testViewport.width - s.innerGap * 2, accuracy: 0.01)
    }

    func testStripMetricsOriginsAndWidths() {
        let s = Scrollini()
        let w1 = makeWindow(100); w1.manualWidthRatio = 0.5
        let w2 = makeWindow(101); w2.manualWidthRatio = 0.5
        let ws = Workspace(); ws.columns = [w1, w2]
        let m = s.stripMetrics(for: ws, viewport: testViewport)
        XCTAssertEqual(m.origins[0], 0, accuracy: 0.001)
        XCTAssertEqual(m.origins[1], m.widths[0] + s.innerGap, accuracy: 0.001)
        XCTAssertEqual(m.widths.count, 2)
    }

    func testMeasuredWidthPacking() {
        let s = Scrollini()
        let w = makeWindow(200); w.manualWidthRatio = 0.8
        let req = s.requestedWidth(for: w, viewport: testViewport)
        XCTAssertFalse(s.recordMeasuredWidth(req + 0.4, requested: req, for: w))
        XCTAssertNil(w.measuredWidth)
        XCTAssertEqual(w.measuredForWidth, req)
        XCTAssertTrue(s.recordMeasuredWidth(req + 20, requested: req, for: w))
        XCTAssertNotNil(w.measuredWidth)
        XCTAssertEqual(s.layoutWidth(for: w, viewport: testViewport), req + 20, accuracy: 0.001)
        w.manualWidthRatio = 0.5
        let newReq = s.requestedWidth(for: w, viewport: testViewport)
        XCTAssertEqual(s.layoutWidth(for: w, viewport: testViewport), newReq, accuracy: 0.001)
    }

    func testMeasuredThreshold() {
        let s = Scrollini()
        let w = makeWindow(201); w.manualWidthRatio = 0.8
        let req = s.requestedWidth(for: w, viewport: testViewport)
        _ = s.recordMeasuredWidth(req + 1.0, requested: req, for: w)
        XCTAssertNotNil(w.measuredWidth)
        _ = s.recordMeasuredWidth(req + 0.9, requested: req, for: w)
        XCTAssertNil(w.measuredWidth)
    }

    func testStripFramesPositioning() {
        let s = Scrollini()
        var cfg = ScrolliniConfig(); cfg.innerGap = 12; cfg.focusAlignment = .smart
        s.loadedConfig = LoadedScrolliniConfig(config: cfg, sourceURL: nil, sourceModificationDate: nil)
        let (model, _) = makeScrolliniWithModel()
        // use workspace 0 with 3 columns
        let ws = model.workspaces[0]
        let frames = s.stripFrames(for: ws, viewport: testViewport, activeColumn: ws.activeColumn, scrollOffset: 0)
        XCTAssertEqual(frames.count, ws.columns.count)
        XCTAssertEqual(frames[0].minX, testViewport.minX + s.innerGap, accuracy: 0.001)
        XCTAssertEqual(frames[0].minY, testViewport.minY, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, testViewport.height, accuracy: 0.001)
    }

    func testDefaultScrollOffsetAlignments() {
        let s = Scrollini()
        let ws = Workspace()
        let a = makeWindow(1); a.manualWidthRatio = 0.5
        let b = makeWindow(2); b.manualWidthRatio = 0.5
        let c = makeWindow(3); c.manualWidthRatio = 0.5
        ws.columns = [a, b, c]
        let m = s.stripMetrics(for: ws, viewport: testViewport)

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .left), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.defaultScrollOffset(metrics: m, activeColumn: 1, viewport: testViewport), m.origins[1], accuracy: 0.001)

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .smart), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.defaultScrollOffset(metrics: m, activeColumn: 0, viewport: testViewport), m.origins[0], accuracy: 0.001)

        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .center), sourceURL: nil, sourceModificationDate: nil)
        let center = s.defaultScrollOffset(metrics: m, activeColumn: 1, viewport: testViewport)
        let expected = m.origins[1] + m.widths[1]/2 + s.innerGap - testViewport.width/2
        XCTAssertEqual(center, max(0, expected), accuracy: 0.001)
    }

    func testHorizontalCameraOffsetClamping() {
        let s = Scrollini()
        let ws = Workspace()
        let w = makeWindow(10); w.manualWidthRatio = 0.8
        ws.columns = [w]
        ws.scrollOffset = -10
        XCTAssertEqual(s.horizontalCameraOffset(for: ws, viewport: testViewport), 0, accuracy: 0.001)
        ws.scrollOffset = 99999
        XCTAssertLessThanOrEqual(s.horizontalCameraOffset(for: ws, viewport: testViewport), s.maxHorizontalCameraOffset(for: ws, viewport: testViewport))
    }

    func testClosestAndMostVisibleColumn() {
        let s = Scrollini()
        let (model, _) = makeScrolliniWithModel()
        let ws = model.workspaces[0]
        s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let off = s.horizontalCameraOffset(for: ws, viewport: testViewport)
        let closest = s.closestColumn(to: off, in: ws, viewport: testViewport)
        XCTAssertTrue((0..<ws.columns.count).contains(closest))
        let most = s.mostVisibleColumn(in: ws, viewport: testViewport, scrollOffset: off)
        XCTAssertTrue((0..<ws.columns.count).contains(most))
    }

    func testParkedFrames() {
        let s = Scrollini()
        let w = makeWindow(400); w.manualWidthRatio = 0.8
        let before = s.parkedFrame(for: w, viewport: testViewport, beforeActive: true)
        let after = s.parkedFrame(for: w, viewport: testViewport, beforeActive: false)
        XCTAssertEqual(before.minX, testViewport.minX - before.width + s.parkedSliverWidth, accuracy: 0.001)
        XCTAssertEqual(after.minX, testViewport.maxX - s.parkedSliverWidth, accuracy: 0.001)
        XCTAssertEqual(before.height, testViewport.height, accuracy: 0.001)
    }

    func testEmptyWorkspaceMetrics() {
        let s = Scrollini()
        let ws = Workspace()
        XCTAssertEqual(s.stripMetrics(for: ws, viewport: testViewport).origins.count, 0)
        XCTAssertEqual(s.maxHorizontalCameraOffset(for: ws, viewport: testViewport), 0)
        XCTAssertEqual(s.closestColumn(to: 0, in: ws, viewport: testViewport), 0)
    }
}

#endif
