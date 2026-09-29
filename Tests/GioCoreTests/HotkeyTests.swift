import XCTest
@testable import GioCore

/// Plan §19: parsing, canonical rendering, defaults, lookup, overrides.
final class HotkeyTests: XCTestCase {
    func testParseBasics() {
        XCTAssertEqual(
            parseHotkey("Alt+H"),
            HotkeyCombo(modifiers: [.alt], key: "H")
        )
        XCTAssertEqual(
            parseHotkey("alt+shift+1"),
            HotkeyCombo(modifiers: [.alt, .shift], key: "1")
        )
        XCTAssertEqual(
            parseHotkey("Option+h"),
            HotkeyCombo(modifiers: [.alt], key: "H")
        )
    }

    func testParseRejectsJunk() {
        XCTAssertNil(parseHotkey(""))
        XCTAssertNil(parseHotkey("H"))
        XCTAssertNil(parseHotkey("Alt+"))
        XCTAssertNil(parseHotkey("Win+H"))
        XCTAssertNil(parseHotkey("Alt++H"))
    }

    func testDescribeIsCanonical() {
        XCTAssertEqual(
            HotkeyCombo(modifiers: [.shift, .alt], key: "H").describe(),
            "Alt+Shift+H"
        )
        XCTAssertEqual(parseHotkey("shift+alt+h")!.describe(), "Alt+Shift+H")
    }

    func testDefaultsCoverPlanBindings() {
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(dispatcher.bindingCount, 35)
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "H")),
            .focusLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "L")),
            .moveRight
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "3")),
            .workspace(3)
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "2")),
            .moveToWorkspace(2)
        )
        XCTAssertNil(dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "T")))
    }

    func testBindUnbindAndOverride() {
        var dispatcher = HotkeyDispatcher()
        let full = HotkeyCombo(modifiers: [.alt], key: "F")
        dispatcher.bind(.fullscreen, to: full)
        XCTAssertEqual(dispatcher.action(for: full), .fullscreen)
        dispatcher.bind(.toggleFloating, to: full)
        XCTAssertEqual(dispatcher.action(for: full), .toggleFloating)
        dispatcher.unbind(full)
        XCTAssertNil(dispatcher.action(for: full))
    }
}
