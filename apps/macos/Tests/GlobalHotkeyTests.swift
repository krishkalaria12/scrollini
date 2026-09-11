#if canImport(XCTest)
import Carbon.HIToolbox
import XCTest
@testable import Scrollini

final class GlobalHotkeyTests: XCTestCase {
    func testCtrlOptionLeftCanUseTheRegisteredHotkeyPath() {
        let scrollini = Scrollini()
        let hotkey = scrollini.globalHotkeySpecification(for: "ctrl+alt+left")

        XCTAssertEqual(hotkey?.keyCode, UInt32(KeyCode.leftArrow))
        XCTAssertEqual(hotkey?.modifiers, UInt32(controlKey | optionKey))
    }

    func testFunctionModifierFallsBackToTheEventTap() {
        let scrollini = Scrollini()
        XCTAssertNil(scrollini.globalHotkeySpecification(for: "ctrl+fn+left"))
    }
}
#endif
