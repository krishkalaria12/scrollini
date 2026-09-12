#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class ConfigAccessorsTests: XCTestCase {

    func testDefaultWidthRatioFallback() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.defaultWidthRatio, 0.8, accuracy: 0.001)
        var c = ScrolliniConfig(); c.defaultWidthRatio = 0.6
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.defaultWidthRatio, 0.6, accuracy: 0.001)
    }

    func testKeyboardAnimationFallback() {
        let s = Scrollini()
        var c = ScrolliniConfig(); c.animationDurationMS = 100; c.keyboardAnimationMS = 150
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.keyboardAnimationDuration, 0.15, accuracy: 0.001)
        var c2 = ScrolliniConfig(); c2.animationDurationMS = 200
        s.loadedConfig = LoadedScrolliniConfig(config: c2, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.keyboardAnimationDuration, 0.2, accuracy: 0.001)
    }

    func testWidthAnimationPreference() {
        let s = Scrollini()
        var c = ScrolliniConfig(); c.widthAnimationMS = 400; c.keyboardAnimationMS = 200; c.animationDurationMS = 100
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.widthAnimationDuration, 0.4, accuracy: 0.001)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(keyboardAnimationMS: 250), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.widthAnimationDuration, 0.25, accuracy: 0.001)
    }

    func testFocusAlignmentCenterFocusedColumnMigration() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(centerFocusedColumn: false), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.focusAlignment, .left)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(centerFocusedColumn: true), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.focusAlignment, .smart)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(focusAlignment: .center), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.focusAlignment, .center)
    }

    func testHoverFocusEnabled() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: false), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertFalse(s.hoverFocusEnabled)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverFocusMode: .off), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertFalse(s.hoverFocusEnabled)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hoverToFocus: true, hoverFocusMode: .edgeOrVisible), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertTrue(s.hoverFocusEnabled)
    }

    func testTrackpadSettleFallback() {
        let s = Scrollini()
        var c = ScrolliniConfig(); c.trackpadNavigationSettleAnimationMS = 123; c.animationDurationMS = 999
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.trackpadSettleAnimationDuration, 0.123, accuracy: 0.001)
        var c2 = ScrolliniConfig(); c2.trackpadNavigationSettleAnimationMS = 240; c2.trackpadSettleAnimationMS = 300
        s.loadedConfig = LoadedScrolliniConfig(config: c2, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.trackpadSettleAnimationDuration, 0.3, accuracy: 0.001)
    }

    func testTrackpadSensitivityFallback() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.trackpadNavigationWorkspaceSensitivity, 6.4, accuracy: 0.001) // fallback is 6.4
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(trackpadNavigationWorkspaceSensitivity: 5.0), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.trackpadNavigationWorkspaceSensitivity, 5.0, accuracy: 0.001)
        XCTAssertEqual(Scrollini().trackpadNavigationWorkspaceSensitivity, 6.4, accuracy: 0.001)
    }

    func testHoverFocusAfterTrackpad() {
        let s = Scrollini()
        var c = ScrolliniConfig(); c.hoverFocusAfterTrackpadMS = 100; c.trackpadNavigationHoverSuppressionMS = 999
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.hoverFocusAfterTrackpad, 0.999, accuracy: 0.001)
    }

    func testGapsAndHideMethod() {
        let s = Scrollini()
        var c = ScrolliniConfig(); c.innerGap = 15; c.outerGap = 20; c.parkedSliverWidth = 2
        s.loadedConfig = LoadedScrolliniConfig(config: c, sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.innerGap, 15)
        XCTAssertEqual(s.outerGap, 20)
        XCTAssertEqual(s.parkedSliverWidth, 2)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(hideMethod: .parkOnly), sourceURL: nil, sourceModificationDate: nil)
        XCTAssertEqual(s.hideMethod, .parkOnly)
    }
}

#endif
