#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class ConfigNormalizationTests: XCTestCase {

    func testInnerGapClamps() {
        var c = ScrolliniConfig.fallback
        c.innerGap = 5000
        XCTAssertEqual(ScrolliniConfig.normalize(c).innerGap, 96)
        c.innerGap = -20
        XCTAssertEqual(ScrolliniConfig.normalize(c).innerGap, 0)
        c.innerGap = 12
        XCTAssertEqual(ScrolliniConfig.normalize(c).innerGap, 12)
    }

    func testOuterGapClamps() {
        var c = ScrolliniConfig.fallback
        c.outerGap = -5
        XCTAssertEqual(ScrolliniConfig.normalize(c).outerGap, 0)
        c.outerGap = 200
        XCTAssertEqual(ScrolliniConfig.normalize(c).outerGap, 96)
    }

    func testRescanClamps() {
        var c = ScrolliniConfig.fallback
        c.rescanIntervalMS = 5
        XCTAssertEqual(ScrolliniConfig.normalize(c).rescanIntervalMS, 100)
        c.rescanIntervalMS = 9999
        XCTAssertEqual(ScrolliniConfig.normalize(c).rescanIntervalMS, 5000)
    }

    func testFingerCountClamps() {
        var c = ScrolliniConfig.fallback
        c.trackpadNavigationWorkspaceFingers = 99
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationWorkspaceFingers, 5)
        c.trackpadNavigationWorkspaceFingers = 1
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationWorkspaceFingers, 2)
    }

    func testAnimationClamps() {
        var c = ScrolliniConfig.fallback
        c.animationDurationMS = 999
        XCTAssertEqual(ScrolliniConfig.normalize(c).animationDurationMS, 500)
        c.animationDurationMS = -5
        XCTAssertEqual(ScrolliniConfig.normalize(c).animationDurationMS, 0)
        c = ScrolliniConfig.fallback
        c.keyboardAnimationMS = -10
        XCTAssertEqual(ScrolliniConfig.normalize(c).keyboardAnimationMS, 0)
        c.hoverFocusDelayMS = 5000
        XCTAssertEqual(ScrolliniConfig.normalize(c).hoverFocusDelayMS, 1000)
        c.hoverFocusMaxScrollRatio = 5
        XCTAssertEqual(ScrolliniConfig.normalize(c).hoverFocusMaxScrollRatio, 2)
        c.hoverFocusRequiresVisibleRatio = -2
        XCTAssertEqual(ScrolliniConfig.normalize(c).hoverFocusRequiresVisibleRatio, 0)
        c.hoverFocusEdgeTriggerWidth = 200
        XCTAssertEqual(ScrolliniConfig.normalize(c).hoverFocusEdgeTriggerWidth, 96)
        c.parkedSliverWidth = 100
        XCTAssertEqual(ScrolliniConfig.normalize(c).parkedSliverWidth, 32)
    }

    func testTrackpadClamps() {
        var c = ScrolliniConfig.fallback
        c.trackpadNavigationWorkspaceSensitivity = 999
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationWorkspaceSensitivity, 40)
        c.trackpadNavigationWorkspaceSensitivity = 0
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationWorkspaceSensitivity, 0.1)
        c = ScrolliniConfig.fallback
        c.trackpadNavigationDirectionLockThreshold = 9
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationDirectionLockThreshold, 0.5)
        c.trackpadNavigationDeceleration = 100
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationDeceleration, 30)
        c.trackpadNavigationMomentumMinVelocity = 99999
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationMomentumMinVelocity, 5000)
        c.trackpadNavigationVelocityGain = 99
        XCTAssertEqual(ScrolliniConfig.normalize(c).trackpadNavigationVelocityGain, 5)
    }

    func testPresetNormalizationSortedDedupedClamped() {
        var c = ScrolliniConfig(presetWidthRatios: [3.0, 0.5, 0.5, -1.0])
        c = ScrolliniConfig.normalize(c)
        XCTAssertEqual(c.presetWidthRatios, [0.05, 0.5, 2.0])

        var c2 = ScrolliniConfig(presetWidthRatios: [0.5, 0.501, 0.502, .infinity, .nan])
        c2 = ScrolliniConfig.normalize(c2)
        XCTAssertEqual(c2.presetWidthRatios?.count, 1)

        var c3 = ScrolliniConfig(presetWidthRatios: [.infinity, .nan])
        c3 = ScrolliniConfig.normalize(c3)
        XCTAssertNil(c3.presetWidthRatios)

        var c4 = ScrolliniConfig(presetWidthRatios: [])
        c4 = ScrolliniConfig.normalize(c4)
        XCTAssertNil(c4.presetWidthRatios)
    }

    func testWidthRatioClamping() {
        XCTAssertEqual(CGFloat(-1).clampedWidthRatio, 0.2)
        XCTAssertEqual(CGFloat(10).clampedWidthRatio, 2.0)
        XCTAssertEqual(CGFloat(0.5).clampedWidthRatio, 0.5)
        XCTAssertEqual(CGFloat(-1).clampedManualWidthRatio, 0.05)
        XCTAssertEqual(CGFloat(3).clampedManualWidthRatio, 2.0)
    }

    func testRuleWorkspaceAndWidthClamping() {
        var c = ScrolliniConfig.fallback
        c.rules = [WindowRule(bundleID: "a", widthRatio: 99, workspace: 200)]
        let n = ScrolliniConfig.normalize(c)
        XCTAssertEqual(n.rules?.first?.workspace, 99)
        XCTAssertEqual(n.rules?.first?.widthRatio, 2.0)
        var c2 = ScrolliniConfig.fallback
        c2.rules = [WindowRule(bundleID: "a", widthRatio: -5, workspace: -5)]
        let n2 = ScrolliniConfig.normalize(c2)
        XCTAssertEqual(n2.rules?.first?.widthRatio, 0.2)
        XCTAssertEqual(n2.rules?.first?.workspace, 1)
    }

    func testConfigJSONLoadValid() throws {
        let json = #"{"default_width_ratio": 0.6, "inner_gap": 20, "rules": [{"bundle_id": "com.test", "behavior": "float"}]}"#
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = ScrolliniConfig.load(from: tmp, logLoaded: false, logErrors: false)
        guard case .loaded(let loaded) = result else { return XCTFail("expected loaded") }
        XCTAssertEqual(loaded.config.defaultWidthRatio, 0.6)
        XCTAssertEqual(loaded.config.innerGap, 20)
        XCTAssertEqual(loaded.config.rules?.count, 1)
    }

    func testConfigJSONInvalidYieldsParseError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        try "{ bad json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = ScrolliniConfig.load(from: tmp, logLoaded: false, logErrors: false)
        if case .parseError = result { } else { XCTFail("expected parseError") }
    }

    func testConfigMissingYieldsNotFound() {
        let url = URL(fileURLWithPath: "/tmp/scrollini-notfound-\(UUID().uuidString).json")
        let result = ScrolliniConfig.load(from: url, logLoaded: false, logErrors: false)
        if case .notFound = result { } else { XCTFail("expected notFound") }
    }

    func testConfigJSONNormalizationViaLoad() throws {
        let json = #"{"inner_gap": 5000, "outer_gap": -5, "preset_width_ratios": [0.5, 0.5, 3.0]}"#
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = ScrolliniConfig.load(from: tmp, logLoaded: false, logErrors: false)
        guard case .loaded(let loaded) = result else { return XCTFail() }
        XCTAssertEqual(loaded.config.innerGap, 96)
        XCTAssertEqual(loaded.config.outerGap, 0)
        XCTAssertEqual(loaded.config.presetWidthRatios, [0.5, 2.0])
    }
}

#endif
