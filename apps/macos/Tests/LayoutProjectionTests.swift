#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class LayoutProjectionTests: XCTestCase {

    func testLayoutItemMatchesFullProjection() {
        let (s, windows) = makeScrolliniWithModel()
        for parkHidden in [true, false] {
            for cameraY in [nil, CGFloat(0), 500, 1000, 2000] {
                for scrollOff in [nil, CGFloat(0), 340] {
                    s.workspaces[0].scrollOffset = scrollOff
                    var state = s.captureLayoutState()
                    state.cameraY = cameraY
                    let all = s.layoutItems(viewport: testViewport, state: state, parkHidden: parkHidden)
                    for w in windows {
                        let expected = all.first { $0.window === w }
                        let actual = s.layoutItem(for: w, viewport: testViewport, state: state, parkHidden: parkHidden)
                        XCTAssertNotNil(expected)
                        XCTAssertNotNil(actual)
                        XCTAssertTrue(sameRect(expected!.frame, actual!.frame))
                        XCTAssertEqual(expected!.visible, actual!.visible)
                    }
                }
            }
        }
    }

    func testCameraY() {
        let s = Scrollini()
        s.workspaces = (0..<5).map { _ in Workspace() }
        let state0 = LayoutState(activeWorkspace: 0, activeColumns: [0,0,0,0,0], scrollOffsets: [nil,nil,nil,nil,nil], cameraY: nil)
        XCTAssertEqual(s.cameraY(for: state0, viewport: testViewport), 0, accuracy: 0.001)
        let state2 = LayoutState(activeWorkspace: 2, activeColumns: [0,0,0,0,0], scrollOffsets: [nil,nil,nil,nil,nil], cameraY: nil)
        XCTAssertEqual(s.cameraY(for: state2, viewport: testViewport), testViewport.height * 2, accuracy: 0.001)
        let cam = LayoutState(activeWorkspace: 0, activeColumns: [0], scrollOffsets: [nil], cameraY: 1234)
        XCTAssertEqual(s.cameraY(for: cam, viewport: testViewport), 1234, accuracy: 0.001)
    }

    func testTrackpadCameraWorkspaceIndex() {
        let s = Scrollini()
        s.workspaces = (0..<5).map { _ in Workspace() }
        XCTAssertEqual(s.trackpadCameraWorkspaceIndex(cameraY: testViewport.height * 1.6, viewport: testViewport), 2)
        XCTAssertEqual(s.trackpadCameraWorkspaceIndex(cameraY: -100, viewport: testViewport), 0)
        XCTAssertEqual(s.trackpadCameraWorkspaceIndex(cameraY: testViewport.height * 100, viewport: testViewport), 4)
        XCTAssertEqual(s.trackpadCameraWorkspaceIndex(cameraY: 100, viewport: CGRect(x: 0,y: 0,width: 1600,height: 0)), 0)
    }

    func testInsetViewport() {
        let s = Scrollini()
        let inset = s.insetViewport(testViewport, by: 20)
        XCTAssertEqual(inset.width, testViewport.width - 40, accuracy: 0.001)
        XCTAssertEqual(s.insetViewport(testViewport, by: 0), testViewport)
        let huge = s.insetViewport(testViewport, by: 9999)
        XCTAssertGreaterThan(huge.width, 0)
    }

    func testLayoutVisibilityParkHidden() {
        let (s, _) = makeScrolliniWithModel()
        s.cachedViewport = testViewport; s.cachedViewportAt = CFAbsoluteTimeGetCurrent()
        let state = s.captureLayoutState()
        let parkTrue = s.layoutItems(viewport: testViewport, state: state, parkHidden: true)
        let parkFalse = s.layoutItems(viewport: testViewport, state: state, parkHidden: false)
        XCTAssertEqual(parkTrue.count, parkFalse.count)
        let active = s.activeWorkspace
        let activeIDs = Set(s.workspaces[active].columns.map(ObjectIdentifier.init))
        let visTrue = parkTrue.filter { activeIDs.contains(ObjectIdentifier($0.window)) && $0.visible }.count
        let visFalse = parkFalse.filter { activeIDs.contains(ObjectIdentifier($0.window)) && $0.visible }.count
        XCTAssertEqual(visTrue, visFalse)
        let nonActive = s.workspaces.enumerated().filter { $0.offset != active }.flatMap { $0.element.columns }
        for w in nonActive {
            if let item = parkTrue.first(where: { $0.window === w }) {
                XCTAssertFalse(item.visible)
            }
        }
        let some = s.workspaces[0].columns[0]
        XCTAssertNotNil(s.layoutItem(for: some, viewport: testViewport, state: state, parkHidden: true))
        XCTAssertNil(s.layoutItem(for: makeWindow(9999), viewport: testViewport, state: state, parkHidden: true))
    }

    func testFramesApproximatelyEqual() {
        let s = Scrollini()
        XCTAssertTrue(s.framesApproximatelyEqual(CGRect(x: 0,y: 0,width: 100,height: 100), CGRect(x: 0,y: 0,width: 100,height: 100), tolerance: 0))
        XCTAssertFalse(s.framesApproximatelyEqual(CGRect(x: 0,y: 0,width: 100,height: 100), CGRect(x: 1,y: 0,width: 100,height: 100), tolerance: 0.5))
        XCTAssertTrue(s.framesApproximatelyEqual(CGRect(x: 0,y: 0,width: 100,height: 100), CGRect(x: 0.4,y: 0.4,width: 100.3,height: 100.3), tolerance: 1))
    }

    func testHorizontalViewportInsetPreservesWorkingHeight() {
        let scrollini = Scrollini()
        let viewport = CGRect(x: 0, y: 25, width: 1600, height: 1000)
        let inset = scrollini.insetViewportHorizontally(viewport, by: 12)

        XCTAssertEqual(inset.minX, 12, accuracy: 0.001)
        XCTAssertEqual(inset.width, 1576, accuracy: 0.001)
        XCTAssertEqual(inset.minY, viewport.minY, accuracy: 0.001)
        XCTAssertEqual(inset.height, viewport.height, accuracy: 0.001)
    }
}

#endif
