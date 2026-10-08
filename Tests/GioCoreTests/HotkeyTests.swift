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
        XCTAssertEqual(dispatcher.bindingCount, 40)
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "H")),
            .focusLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "L")),
            .moveColumnRight
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "H")),
            .moveColumnLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "J")),
            .moveDown
        )
        XCTAssertEqual(parseActionName("move-column-left"), .moveColumnLeft)
        XCTAssertEqual(parseActionName("move-column-right"), .moveColumnRight)
        XCTAssertEqual(parseActionName("move-window-left"), .moveLeft)
        XCTAssertEqual(parseActionName("move-window-right"), .moveRight)
        XCTAssertEqual(parseActionName("move-left"), .moveLeft)
        XCTAssertEqual(parseActionName("move-right"), .moveRight)
        XCTAssertTrue(validActionNames().contains("move-column-left"))
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

    func testNiriWorkspaceNavigationDefaults() {
        let dispatcher = HotkeyDispatcher()
        func action(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyAction? {
            dispatcher.action(for: HotkeyCombo(modifiers: modifiers, key: key))
        }
        XCTAssertEqual(action([.alt], "U"), .focusWorkspaceDown)
        XCTAssertEqual(action([.alt], "I"), .focusWorkspaceUp)
        XCTAssertEqual(action([.alt, .shift], "U"), .moveWindowToWorkspaceDown)
        XCTAssertEqual(action([.alt, .shift], "I"), .moveWindowToWorkspaceUp)
    }

    func testOverviewDefaultsToAltOLikeNiri() {
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "O")), .toggleOverview)
        XCTAssertEqual(parseActionName("toggle-overview"), .toggleOverview)
        XCTAssertTrue(validActionNames().contains("toggle-overview"))
        XCTAssertFalse(HotkeyAction.toggleOverview.carriesFocusIntent)
    }

    func testNiriWorkspaceActionNamesParse() {
        XCTAssertEqual(parseActionName("focus-workspace-down"), .focusWorkspaceDown)
        XCTAssertEqual(parseActionName("focus-workspace-up"), .focusWorkspaceUp)
        XCTAssertEqual(parseActionName("move-window-to-workspace-down"), .moveWindowToWorkspaceDown)
        XCTAssertEqual(parseActionName("move-window-to-workspace-up"), .moveWindowToWorkspaceUp)
        for name in [
            "focus-workspace-down", "focus-workspace-up",
            "move-window-to-workspace-down", "move-window-to-workspace-up",
        ] {
            XCTAssertTrue(validActionNames().contains(name), name)
        }
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
