#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class TrackpadAndFocusTests: XCTestCase {

    func testTrackpadDeltaSigns() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(trackpadNavigationSensitivity: 1.6, trackpadNavigationWorkspaceSensitivity: 6.4, trackpadNavigationVelocityGain: 1.35), sourceURL: nil, sourceModificationDate: nil)
        let d = s.trackpadCameraDelta(from: CGPoint(x: 0.01, y: 0.02), velocity: .zero, viewport: testViewport)
        XCTAssertLessThan(d.width, 0)
        XCTAssertGreaterThan(d.height, 0)
    }

    func testVelocityGainCaps() {
        let s = Scrollini()
        let slow = s.trackpadCameraVelocityGain(for: CGPoint(x: 0.1, y: 0.1))
        let fast = s.trackpadCameraVelocityGain(for: CGPoint(x: 2, y: 2))
        XCTAssertGreaterThanOrEqual(fast, slow)
        XCTAssertLessThanOrEqual(fast, 1 + s.trackpadNavigationVelocityGain)
    }

    func testPendingAndMomentumThresholds() {
        let s = Scrollini()
        XCTAssertFalse(s.hasPendingTrackpadCameraDelta)
        s.trackpadPendingCameraDelta = CGSize(width: 0.6, height: 0)
        XCTAssertTrue(s.hasPendingTrackpadCameraDelta)
        s.trackpadPendingCameraDelta = .zero
        s.trackpadCameraVelocity = CGPoint(x: 10, y: 0)
        XCTAssertFalse(s.hasTrackpadMomentumVelocity)
        s.trackpadCameraVelocity = CGPoint(x: 100, y: 0)
        XCTAssertTrue(s.hasTrackpadMomentumVelocity)
    }

    func testStrongestVelocity() {
        let s = Scrollini()
        s.trackpadLatestCameraVelocity = CGPoint(x: 50, y: 0)
        XCTAssertEqual(s.strongestTrackpadCameraVelocity(endingVelocity: CGPoint(x: 30, y: 0)).x, 50, accuracy: 0.001)
        XCTAssertEqual(s.strongestTrackpadCameraVelocity(endingVelocity: CGPoint(x: 60, y: 0)).x, 60, accuracy: 0.001)
    }

    func testApplyDeltaClamps() {
        let (s, _) = makeScrolliniWithModel()
        s.trackpadCameraY = nil
        s.workspaces[0].scrollOffset = nil
        s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let clamped = s.applyTrackpadCameraDelta(CGSize(width: 10000, height: 10000), viewport: testViewport)
        XCTAssertTrue(clamped.x || clamped.y)
    }

    func testFocusExpectations() {
        let s = Scrollini()
        s.workspaces = [Workspace()]
        let w = makeWindow(600)
        s.workspaces[0].columns = [w]
        XCTAssertFalse(s.shouldSuppressFocusedWindowAdoption)
        s.suppressFocusedWindowAdoption(for: 10)
        XCTAssertTrue(s.shouldSuppressFocusedWindowAdoption)
        s.markExpectedFocusedWindow(for: w, duration: 5)
        XCTAssertEqual(s.expectedFocusedWindowID(), ObjectIdentifier(w))
        let until1 = s.expectedFocusedWindowUntil
        s.markExpectedFocusedWindow(for: w, duration: 1)
        XCTAssertGreaterThanOrEqual(s.expectedFocusedWindowUntil, until1)
        let w2 = makeWindow(601)
        s.markExpectedFocusedWindow(for: w2, duration: 0.3)
        XCTAssertEqual(s.expectedFocusedWindowID(), ObjectIdentifier(w2))
        s.releaseExpectedFocusedWindow()
        XCTAssertNil(s.expectedFocusedWindowID())
        s.markExpectedFocusedWindow(for: w, duration: 1)
        s.markExpectedFocusedWindow(for: nil, duration: 1)
        XCTAssertNil(s.expectedFocusedWindowID())
    }

    func testColumnNavigationBurst() {
        let s = Scrollini()
        s.lastColumnNavigationAt = CFAbsoluteTimeGetCurrent()
        s.lastColumnNavigationDirection = 1
        XCTAssertTrue(s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1))
        s.lastColumnNavigationAt = CFAbsoluteTimeGetCurrent() - 1
        XCTAssertFalse(s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1))
        s.animationTimer = s.makeMainTimer(deadline: .now() + .seconds(10)) {}
        XCTAssertTrue(s.columnNavigationBurstIsActive(at: CFAbsoluteTimeGetCurrent(), stepCount: 1))
        s.cancelTimer(&s.animationTimer)
        s.pendingColumnNavigationDelta = 2
        s.pendingColumnNavigationStartedAt = 0
        s.enqueueColumnNavigation(delta: 0)
        XCTAssertEqual(s.pendingColumnNavigationDelta, 2) // zero does nothing
        s.pendingColumnNavigationDelta = 0
        s.enqueueColumnNavigation(delta: 2)
        XCTAssertEqual(s.pendingColumnNavigationDelta, 2)
        s.cancelTimer(&s.pendingColumnNavigationTimer)
    }
}

#endif
