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
        XCTAssertEqual(dispatcher.bindingCount, 75)
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

    func testMonitorActionDefaultsAndNames() {
        let dispatcher = HotkeyDispatcher()
        func action(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyAction? {
            dispatcher.action(for: HotkeyCombo(modifiers: modifiers, key: key))
        }
        let keys: [(String, FocusDirection)] = [("H", .left), ("J", .down), ("K", .up), ("L", .right)]
        for (key, direction) in keys {
            XCTAssertEqual(action([.alt, .ctrl], key), .focusMonitor(direction), key)
            XCTAssertEqual(action([.alt, .ctrl, .shift], key), .moveColumnToMonitor(direction), key)
            // MM-04: the window move is bound too, Command for "window".
            XCTAssertEqual(action([.alt, .ctrl, .cmd], key), .moveWindowToMonitor(direction), key)
        }
        // Alt+H/L keep focusing columns.
        XCTAssertEqual(action([.alt], "H"), .focusLeft)
        XCTAssertEqual(action([.alt], "L"), .focusRight)
        let directions: [(String, FocusDirection)] = [("left", .left), ("right", .right), ("up", .up), ("down", .down)]
        for (suffix, direction) in directions {
            let named: [(String, HotkeyAction)] = [
                ("focus-monitor-\(suffix)", .focusMonitor(direction)),
                ("move-column-to-monitor-\(suffix)", .moveColumnToMonitor(direction)),
                ("move-window-to-monitor-\(suffix)", .moveWindowToMonitor(direction)),
                ("move-workspace-to-monitor-\(suffix)", .moveWorkspaceToMonitor(direction)),
            ]
            for (name, expected) in named {
                XCTAssertEqual(parseActionName(name), expected, name)
                XCTAssertTrue(validActionNames().contains(name), name)
            }
        }
        // Workspace moves ship unbound.
        let bound = defaultHotkeyBindings().map(\.1)
        for direction in [FocusDirection.left, .right, .up, .down] {
            XCTAssertFalse(bound.contains(.moveWorkspaceToMonitor(direction)))
        }
    }

    func testDefaultCombosAreUnique() {
        let combos = defaultHotkeyBindings().map(\.0)
        XCTAssertEqual(combos.count, 75)
        XCTAssertEqual(Set(combos).count, combos.count, "a default combo is bound twice")
        XCTAssertFalse(combos.contains(launcherHotkey), "Alt+Space stays the launcher")
    }

    /// NC-08..NC-11: niri's defaults with Alt as Mod, where the combo is free.
    func testNiriColumnHeightAndWorkspaceDefaults() {
        let dispatcher = HotkeyDispatcher()
        func action(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyAction? {
            dispatcher.action(for: HotkeyCombo(modifiers: modifiers, key: key))
        }
        XCTAssertEqual(action([.alt], "Home"), .focusColumnFirst)
        XCTAssertEqual(action([.alt], "End"), .focusColumnLast)
        XCTAssertEqual(action([.alt, .ctrl], "Home"), .moveColumnToFirst)
        XCTAssertEqual(action([.alt, .ctrl], "End"), .moveColumnToLast)
        XCTAssertEqual(action([.alt, .shift], "Minus"), .shrinkWindowHeight)
        XCTAssertEqual(action([.alt, .shift], "Equal"), .growWindowHeight)
        XCTAssertEqual(action([.alt, .shift], "R"), .switchPresetWindowHeight)
        XCTAssertEqual(action([.alt, .ctrl], "R"), .resetWindowHeight)
        XCTAssertEqual(action([.alt, .ctrl], "U"), .moveColumnToWorkspaceDown)
        XCTAssertEqual(action([.alt, .ctrl], "I"), .moveColumnToWorkspaceUp)
        XCTAssertEqual(action([.alt, .ctrl, .shift], "U"), .moveWorkspaceDown)
        XCTAssertEqual(action([.alt, .ctrl, .shift], "I"), .moveWorkspaceUp)
        for number in 1...9 {
            XCTAssertEqual(action([.alt, .ctrl], "\(number)"), .moveColumnToWorkspace(number))
        }
        // Option+Tab is the default of the AltTab app switcher: left unbound.
        XCTAssertNil(action([.alt], "Tab"))
        let bound = defaultHotkeyBindings().map(\.1)
        for unbound: HotkeyAction in [
            .focusWorkspacePrevious, .swapWindowLeft, .swapWindowRight,
            .focusWindowOrWorkspaceDown, .focusWindowOrWorkspaceUp, .switchPresetColumnWidthBack,
        ] {
            XCTAssertFalse(bound.contains(unbound), "\(unbound) ships unbound")
        }
        // NC-12: niri Mod+Ctrl+F / Mod+Ctrl+C.
        XCTAssertEqual(action([.alt, .ctrl], "F"), .expandColumnToAvailableWidth)
        XCTAssertEqual(action([.alt, .ctrl], "C"), .centerVisibleColumns)
    }

    func testNiriColumnHeightAndWorkspaceActionNamesParse() {
        let named: [(String, HotkeyAction)] = [
            ("set-window-height-minus", .shrinkWindowHeight),
            ("set-window-height-plus", .growWindowHeight),
            ("switch-preset-window-height", .switchPresetWindowHeight),
            ("reset-window-height", .resetWindowHeight),
            ("focus-column-first", .focusColumnFirst),
            ("focus-column-last", .focusColumnLast),
            ("move-column-to-first", .moveColumnToFirst),
            ("move-column-to-last", .moveColumnToLast),
            ("swap-window-left", .swapWindowLeft),
            ("swap-window-right", .swapWindowRight),
            ("move-column-to-workspace-down", .moveColumnToWorkspaceDown),
            ("move-column-to-workspace-up", .moveColumnToWorkspaceUp),
            ("focus-workspace-previous", .focusWorkspacePrevious),
            ("move-workspace-down", .moveWorkspaceDown),
            ("move-workspace-up", .moveWorkspaceUp),
            ("focus-window-or-workspace-down", .focusWindowOrWorkspaceDown),
            ("focus-window-or-workspace-up", .focusWindowOrWorkspaceUp),
            ("switch-preset-column-width-back", .switchPresetColumnWidthBack),
            ("expand-column-to-available-width", .expandColumnToAvailableWidth),
            ("center-visible-columns", .centerVisibleColumns),
        ]
        for (name, expected) in named {
            XCTAssertEqual(parseActionName(name), expected, name)
            XCTAssertTrue(validActionNames().contains(name), name)
            XCTAssertEqual(configActionName(expected), name)
        }
        XCTAssertEqual(parseActionName("move-column-to-workspace 4"), .moveColumnToWorkspace(4))
        XCTAssertNil(parseActionName("move-column-to-workspace x"))
        XCTAssertEqual(configActionName(.moveColumnToWorkspace(4)), "move-column-to-workspace 4")
        XCTAssertTrue(validActionNames().contains("move-column-to-workspace N"))
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
