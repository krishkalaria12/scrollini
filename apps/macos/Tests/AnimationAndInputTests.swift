#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class AnimationAndInputTests: XCTestCase {

    func testInterpolate() {
        let s = Scrollini()
        let a = CGRect(x: 0,y: 0,width: 100,height: 100)
        let b = CGRect(x: 100,y: 200,width: 300,height: 400)
        XCTAssertEqual(s.interpolate(from: a, to: b, progress: 0), a)
        XCTAssertEqual(s.interpolate(from: a, to: b, progress: 1), b)
        let mid = s.interpolate(from: a, to: b, progress: 0.5)
        XCTAssertEqual(mid.minX, 50, accuracy: 0.001)
        XCTAssertEqual(mid.minY, 100, accuracy: 0.001)
        XCTAssertEqual(mid.width, 200, accuracy: 0.001)
    }

    func testSoftSettleCurve() {
        let s = Scrollini()
        XCTAssertEqual(s.softSettleCurve(0), 0, accuracy: 0.001)
        XCTAssertEqual(s.softSettleCurve(1), 1, accuracy: 0.001)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .linear), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.softSettleCurve(0.4), 0.4, accuracy: 0.001)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .smooth), sourceURL: nil, sourceModificationDate: nil)
        let v1 = s.softSettleCurve(0.3), v2 = s.softSettleCurve(0.6)
        XCTAssertLessThan(v1, v2)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(animationCurve: .snappy), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertLessThan(s.softSettleCurve(0.3), s.softSettleCurve(0.6))
    }

    func testCubicBezierEndpoints() {
        let s = Scrollini()
        XCTAssertEqual(s.cubicBezier(0, x1: 0.16, y1: 0, x2: 0.18, y2: 1), 0, accuracy: 0.001)
        XCTAssertEqual(s.cubicBezier(1, x1: 0.16, y1: 0, x2: 0.18, y2: 1), 1, accuracy: 0.001)
    }

    func testFramesApproximatelyEqual() {
        let s = Scrollini()
        XCTAssertTrue(s.framesApproximatelyEqual(CGRect(x: 0,y: 0,width: 100,height: 100), CGRect(x: 0.4,y: 0.4,width: 100.3,height: 100.3), tolerance: 1))
        XCTAssertFalse(s.framesApproximatelyEqual(CGRect(x: 0,y: 0,width: 100,height: 100), CGRect(x: 5,y: 0,width: 100,height: 100), tolerance: 1))
    }

    func testSystemSwitcher() {
        let s = Scrollini()
        XCTAssertTrue(s.isSystemWindowSwitcherEvent(modifiers: .maskCommand, keyCode: KeyCode.tab, keyText: "tab"))
        XCTAssertFalse(s.isSystemWindowSwitcherEvent(modifiers: .maskControl, keyCode: KeyCode.tab, keyText: "tab"))
        XCTAssertFalse(s.isSystemWindowSwitcherEvent(modifiers: .maskCommand, keyCode: KeyCode.a, keyText: "a"))
    }

    func testOrderedModifierParts() {
        let s = Scrollini()
        XCTAssertEqual(s.orderedModifierParts(from: ["alt","cmd","shift"]), ["cmd","shift","alt"])
        XCTAssertEqual(s.normalizedModifierParts(from: [.maskCommand, .maskShift]), ["cmd","shift"])
    }

    func testManualResizeInverse() {
        let s = Scrollini()
        let width: CGFloat = 800
        let ratio = s.widthRatio(forWidth: width, viewport: testViewport)
        let w = makeWindow(500); w.manualWidthRatio = ratio
        XCTAssertEqual(s.requestedWidth(for: w, viewport: testViewport), width, accuracy: 1.0)
        XCTAssertEqual(s.widthRatio(forWidth: 100, viewport: CGRect(x: 0,y: 0,width: 12,height: 1000)), 0.8, accuracy: 0.001)
    }

    func testTransientHelpers() {
        let s = Scrollini()
        XCTAssertTrue(s.isTransientRole("AXSheet"))
        XCTAssertTrue(s.isTransientRole("AXDialog"))
        XCTAssertFalse(s.isTransientRole(kAXWindowRole))
        XCTAssertTrue(s.isTransientSubrole("AXSystemDialog"))
        XCTAssertFalse(s.isTransientSubrole(kAXStandardWindowSubRole))
        XCTAssertTrue(s.transientFrameNeedsRecovery(CGRect(x: -5000,y: -5000,width: 100,height: 100), viewport: testViewport))
        XCTAssertFalse(s.transientFrameNeedsRecovery(CGRect(x: testViewport.midX-50,y: testViewport.midY-50,width: 100,height: 100), viewport: testViewport))
        let centered = s.centeredOrigin(for: CGRect(x: 0,y: 0,width: 200,height: 200), in: testViewport)
        XCTAssertEqual(centered.x, testViewport.midX - 100, accuracy: 0.001)
    }
}

#endif
