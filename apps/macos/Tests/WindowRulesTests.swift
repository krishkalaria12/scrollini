#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class WindowRulesTests: XCTestCase {

    func testPerFieldResolution() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(newWindowPosition: .end, rules: [
            WindowRule(bundleID: "com.test.0", behavior: .float),
            WindowRule(bundleID: "com.test.0", widthRatio: 0.5, workspace: 3, openPosition: .beforeActive, hoverToFocus: false)
        ]), sourceURL: nil, sourceModificationDate: nil)
        let w = makeWindow(0, bundleID: "com.test.0")
        XCTAssertEqual(s.behavior(for: w), .float)
        XCTAssertEqual(s.workspace(for: w), 3)
        XCTAssertEqual(s.openPosition(for: w), .beforeActive)
        XCTAssertEqual(s.hoverToFocusAllowed(for: w), false)
        XCTAssertEqual(s.widthRatio(for: w), 0.5, accuracy: 0.001)
    }

    func testTitleContainsCaseAndDiacriticInsensitive() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(rules: [WindowRule(titleContains: "Preferences", behavior: .float)]), sourceURL: nil, sourceModificationDate: nil)
        let w1 = makeWindow(10); w1.title = "preferences"
        XCTAssertEqual(s.behavior(for: w1), .float)
        let w2 = makeWindow(11); w2.title = "PREFÉRENCES"
        XCTAssertEqual(s.behavior(for: w2), .float)
    }

    func testRetitlingRetiresTheCachedRuleAnswer() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(rules: [
            WindowRule(titleContains: "Preferences", behavior: .float, widthRatio: 0.5)
        ]), sourceURL: nil, sourceModificationDate: nil)
        let w = makeWindow(30, title: "Inbox")
        XCTAssertEqual(s.behavior(for: w), .tile)
        w.title = "App Preferences"
        XCTAssertEqual(s.behavior(for: w), .float)
        XCTAssertEqual(s.widthRatio(for: w), 0.5, accuracy: 0.001)
        w.title = "Inbox"
        XCTAssertEqual(s.behavior(for: w), .tile)
    }

    func testReloadingConfigRetiresTheCachedRuleAnswer() {
        let s = Scrollini()
        let w = makeWindow(31, bundleID: "com.test.31")
        XCTAssertEqual(s.behavior(for: w), .tile)
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(rules: [
            WindowRule(bundleID: "com.test.31", behavior: .ignore, workspace: 2)
        ]), sourceURL: nil, sourceModificationDate: nil)
        s.configureInput()
        XCTAssertEqual(s.behavior(for: w), .ignore)
        XCTAssertEqual(s.workspace(for: w), 2)
    }

    func testNoRuleYieldsDefaults() {
        let s = Scrollini()
        let w = makeWindow(20)
        XCTAssertEqual(s.behavior(for: w), .tile)
        XCTAssertEqual(s.widthRatio(for: w), 0.8, accuracy: 0.001)
        XCTAssertNil(s.workspace(for: w))
        XCTAssertTrue(s.hoverToFocusAllowed(for: w))
    }

    func testMatchesApplicationRequiresBundleOrAppName() {
        let titleOnly = WindowRule(titleContains: "Zoom", excludedKeybindings: ["ctrl+alt+left"])
        XCTAssertFalse(titleOnly.matchesApplication(bundleID: "com.zoom", appName: "Zoom"))
        let bundle = WindowRule(bundleID: "com.zoom", excludedKeybindings: ["ctrl+alt+left"])
        XCTAssertTrue(bundle.matchesApplication(bundleID: "com.zoom", appName: "Zoom"))
        XCTAssertFalse(bundle.matchesApplication(bundleID: "com.other", appName: "Zoom"))
    }

    func testWidthRatioManualWinsAndClamps() {
        let s = Scrollini()
        let w = makeWindow(20)
        XCTAssertEqual(s.widthRatio(for: w), 0.8, accuracy: 0.001)
        w.manualWidthRatio = 0.6
        XCTAssertEqual(s.widthRatio(for: w), 0.6, accuracy: 0.001)
        w.manualWidthRatio = 99
        XCTAssertEqual(s.widthRatio(for: w), 2.0, accuracy: 0.001)
        w.manualWidthRatio = -5
        XCTAssertEqual(s.widthRatio(for: w), 0.05, accuracy: 0.001)
    }

    func testOpenPositionFallback() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(newWindowPosition: .end), sourceURL: nil, sourceModificationDate: nil)
        let w = makeWindow(1)
        XCTAssertEqual(s.openPosition(for: w), .end)
    }
}

#endif
