import AppKit
import GioCore
import XCTest
@testable import GioUI

/// The menu bar's Launcher item shows the combo that opens the launcher
/// now (it can be rebound or removed), not a fixed ⌥Space.
final class MenuKeyEquivalentTests: XCTestCase {
    private func combo(_ text: String) -> HotkeyCombo { parseHotkey(text)! }

    func testTypableKeysBecomeKeyEquivalents() {
        let space = menuKeyEquivalent(for: combo("Alt+Space"))
        XCTAssertEqual(space?.key, " ")
        XCTAssertEqual(space?.modifiers, [.option])
        let letter = menuKeyEquivalent(for: combo("Ctrl+Alt+P"))
        XCTAssertEqual(letter?.key, "p")
        XCTAssertEqual(letter?.modifiers, [.control, .option])
        XCTAssertEqual(menuKeyEquivalent(for: combo("Alt+Shift+BracketLeft"))?.key, "[")
        XCTAssertEqual(menuKeyEquivalent(for: combo("Cmd+7"))?.modifiers, [.command])
    }

    func testAnUnboundOrUntypableComboShowsNone() {
        XCTAssertNil(menuKeyEquivalent(for: nil))
        XCTAssertNil(menuKeyEquivalent(for: combo("Alt+Home")))
        XCTAssertNil(menuKeyEquivalent(for: combo("Alt+F5")))
    }
}
