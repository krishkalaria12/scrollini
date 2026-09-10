#if canImport(XCTest)
import XCTest
import CoreGraphics
@testable import Scrollini

final class KeybindingTests: XCTestCase {

    func testModifierSpellingsCollapse() {
        let s = Scrollini()
        XCTAssertEqual(s.normalizedKeybinding("Option+Control+Left"), s.normalizedKeybinding("ctrl+alt+leftarrow"))
        XCTAssertEqual(s.normalizedKeybinding("alt+ctrl+r"), s.normalizedKeybinding("ctrl+alt+r"))
        XCTAssertEqual(s.normalizedKeybinding("ctrl+alt+minus"), s.normalizedKeybinding("ctrl+alt+-"))
        XCTAssertEqual(s.normalizedKeybinding("super+a"), s.normalizedKeybinding("cmd+a"))
        XCTAssertEqual(s.normalizedKeybinding("CTRL+ALT+R"), "ctrl+alt+r")
    }

    func testChordWithoutKeyRejected() {
        XCTAssertNil(Scrollini().normalizedKeybinding("ctrl+alt"))
    }

    func testEveryDefaultParsesAndMaps() {
        let s = Scrollini()
        for chord in ScrolliniConfig.defaultKeybindings.values.flatMap({ $0 }) {
            XCTAssertNotNil(s.normalizedKeybinding(chord), "chord \(chord) should parse")
        }
        for name in ScrolliniConfig.defaultKeybindings.keys {
            XCTAssertNotNil(s.command(named: name), "command \(name) should map")
        }
    }

    func testBracketsAliases() {
        let s = Scrollini()
        XCTAssertEqual(s.normalizedKeybinding("ctrl+alt+leftbracket"), s.normalizedKeybinding("ctrl+alt+["))
        XCTAssertNotNil(s.normalizedKeybinding("ctrl+alt+shift+["))
    }

    func testFnCandidates() {
        let s = Scrollini()
        let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn]
        let candidates = s.normalizedKeybindingCandidates(modifiers: mods, keyCode: KeyCode.leftArrow, keyText: "")
        XCTAssertTrue(candidates.contains("ctrl+alt+fn+home") || candidates.contains("ctrl+alt+home"))
        XCTAssertTrue(candidates.contains("ctrl+alt+left"))
    }

    func testCommandMapping() {
        let s = Scrollini()
        XCTAssertNotNil(s.command(named: "focus_workspace_5"))
        XCTAssertNil(s.command(named: "focus_workspace_0"))
        XCTAssertNil(s.command(named: "focus_workspace_10"))
        XCTAssertNil(s.command(named: "nonexistent"))
        XCTAssertEqual(s.commandIndex("focus_workspace_3", prefix: "focus_workspace_"), 3)
        XCTAssertNil(s.commandIndex("focus_workspace_0", prefix: "focus_workspace_"))
    }

    func testExcludedKeybindingSets() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(excludedKeybindings: ["ctrl+alt+left"], rules: [
            WindowRule(bundleID: "com.test.app", excludedKeybindings: ["ctrl+alt+up"]),
            WindowRule(titleContains: "onlyTitle", excludedKeybindings: ["ctrl+alt+down"])
        ]), sourceURL: nil, sourceModificationDate: nil)
        s.configureInput()
        XCTAssertTrue(s.excludedKeybindingSet.contains("ctrl+alt+left"))
        XCTAssertEqual(s.appKeybindingExclusions.count, 1)
        s.frontmostAppBundleID = "com.test.app"
        s.frontmostAppName = "Test"
        let mods: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertTrue(s.isExcludedKeybinding(modifiers: mods, keyCode: KeyCode.upArrow, keyText: ""))
        s.frontmostAppBundleID = "com.other"
        XCTAssertFalse(s.isExcludedKeybinding(modifiers: mods, keyCode: KeyCode.upArrow, keyText: ""))
    }

    func testMakeCommandByKeybindingIgnoresUnknown() {
        let s = Scrollini()
        s.loadedConfig = LoadedScrolliniConfig(config: ScrolliniConfig(keybindings: ["focus_workspace_1": ["ctrl+alt+1"], "unknown_cmd": ["ctrl+alt+z"]]), sourceURL: nil, sourceModificationDate: nil)
        let cmds = s.makeCommandByKeybinding()
        XCTAssertGreaterThanOrEqual(cmds.count, 1)
    }
}

#endif
