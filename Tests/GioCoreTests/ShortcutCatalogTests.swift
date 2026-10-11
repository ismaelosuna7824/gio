import XCTest
@testable import GioCore

final class ShortcutCatalogTests: XCTestCase {
    private func combo(_ text: String) -> HotkeyCombo { parseHotkey(text)! }

    func testEveryConfigurableActionNameHasAnEntry() {
        let entries = shortcutCatalog(configKeybindings: [])
        for name in validActionNames() {
            XCTAssertTrue(
                entries.contains { $0.configName == name }, "no catalog entry for '\(name)'"
            )
        }
    }

    func testEveryDefaultBindingLandsOnAnEntry() {
        let entries = shortcutCatalog(configKeybindings: [])
        for (hotkey, action) in defaultHotkeyBindings() {
            let entry = entries.first { $0.id == shortcutFamily(of: action) }
            XCTAssertNotNil(entry, "\(action) has no entry")
            XCTAssertTrue(
                entry?.bindings.contains { $0.combo == hotkey && $0.source == .default } ?? false,
                "\(hotkey.describe()) missing on \(action)"
            )
        }
    }

    func testEntriesHaveNamesDescriptionsAndUniqueIds() {
        let entries = shortcutCatalog(configKeybindings: [])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.summary.isEmpty, "\(entry.id) has no description")
        }
    }

    func testCategoriesCoverEveryEntryAndAreOrdered() {
        XCTAssertEqual(
            ShortcutCategory.allCases.map(\.title),
            ["Focus", "Move", "Columns", "Windows", "Workspaces", "Monitors", "App"]
        )
        let entries = shortcutCatalog(configKeybindings: [])
        for category in ShortcutCategory.allCases {
            XCTAssertTrue(entries.contains { $0.category == category }, "\(category) is empty")
        }
    }

    func testWorkspaceFamilyGroupsNineBindingsInOrder() {
        let entries = shortcutCatalog(configKeybindings: [])
        let goto = entries.first { $0.configName == "workspace N" }
        XCTAssertEqual(goto?.bindings.map(\.combo.key), (1...9).map(String.init))
        XCTAssertEqual(goto?.category, .workspaces)
    }

    func testNiriWorkspaceNavigationEntries() {
        let entries = shortcutCatalog(configKeybindings: [])
        func keys(_ name: String) -> [String] {
            entries.first { $0.configName == name }?.bindings.map { $0.combo.describe() } ?? []
        }
        XCTAssertEqual(keys("focus-workspace-down"), ["Alt+U"])
        XCTAssertEqual(keys("focus-workspace-up"), ["Alt+I"])
        XCTAssertEqual(keys("move-window-to-workspace-down"), ["Alt+Shift+U"])
        XCTAssertEqual(keys("move-window-to-workspace-up"), ["Alt+Shift+I"])
        XCTAssertEqual(entries.first { $0.configName == "focus-workspace-down" }?.category, .workspaces)
    }

    func testMonitorEntriesOnePerDirectionWithCtrlAltDefaults() {
        let entries = shortcutCatalog(configKeybindings: [])
        func keys(_ name: String) -> [String] {
            entries.first { $0.configName == name }?.bindings.map { $0.combo.describe() } ?? ["missing"]
        }
        for (suffix, key) in [("left", "H"), ("down", "J"), ("up", "K"), ("right", "L")] {
            XCTAssertEqual(keys("focus-monitor-\(suffix)"), ["Ctrl+Alt+\(key)"])
            XCTAssertEqual(keys("move-column-to-monitor-\(suffix)"), ["Ctrl+Alt+Shift+\(key)"])
            XCTAssertEqual(keys("move-window-to-monitor-\(suffix)"), ["Ctrl+Alt+Cmd+\(key)"], "bound by MM-04")
            XCTAssertEqual(keys("move-workspace-to-monitor-\(suffix)"), [], "unbound")
        }
        let monitors = entries.filter { $0.category == .monitors }.compactMap(\.configName)
        XCTAssertEqual(monitors.count, 20)
        XCTAssertEqual(Array(monitors.prefix(4)), [
            "focus-monitor-left", "focus-monitor-right", "focus-monitor-up", "focus-monitor-down",
        ])
        // MM-06: the edge-crossing column actions close the category, unbound.
        XCTAssertEqual(Array(monitors.suffix(4)), [
            "move-column-left-or-to-monitor-left", "move-column-right-or-to-monitor-right",
            "focus-column-or-monitor-left", "focus-column-or-monitor-right",
        ])
        for name in monitors.suffix(4) {
            XCTAssertEqual(keys(name), [], "\(name) ships unbound")
        }
    }

    func testNiriColumnHeightAndWorkspaceEntries() {
        let entries = shortcutCatalog(configKeybindings: [])
        func entry(_ name: String) -> ShortcutEntry? {
            entries.first { $0.configName == name }
        }
        let expected: [(String, ShortcutCategory, [String])] = [
            ("focus-column-first", .focus, ["Alt+Home"]),
            ("focus-column-last", .focus, ["Alt+End"]),
            ("move-column-to-first", .move, ["Ctrl+Alt+Home"]),
            ("move-column-to-last", .move, ["Ctrl+Alt+End"]),
            ("swap-window-left", .move, []),
            ("swap-window-right", .move, []),
            ("switch-preset-window-height", .windows, ["Alt+Shift+R"]),
            ("set-window-height-minus", .windows, ["Alt+Shift+Minus"]),
            ("set-window-height-plus", .windows, ["Alt+Shift+Equal"]),
            ("reset-window-height", .windows, ["Ctrl+Alt+R"]),
            ("move-column-to-workspace-down", .workspaces, ["Ctrl+Alt+U"]),
            ("move-column-to-workspace-up", .workspaces, ["Ctrl+Alt+I"]),
            ("focus-workspace-previous", .workspaces, []),
            ("move-workspace-down", .workspaces, ["Ctrl+Alt+Shift+U"]),
            ("move-workspace-up", .workspaces, ["Ctrl+Alt+Shift+I"]),
        ]
        for (name, category, keys) in expected {
            XCTAssertEqual(entry(name)?.category, category, name)
            XCTAssertEqual(entry(name)?.bindings.map { $0.combo.describe() }, keys, name)
        }
        let column = entry("move-column-to-workspace N")
        XCTAssertEqual(column?.category, .workspaces)
        XCTAssertEqual(column?.bindings.map { $0.combo.describe() }, (1...9).map { "Ctrl+Alt+\($0)" })
        XCTAssertEqual(column?.action, .moveColumnToWorkspace(1))
    }

    func testAltShiftHLMoveColumnsAndOldStackingMovesAreUnbound() {
        let entries = shortcutCatalog(configKeybindings: [])
        func keys(_ name: String) -> [String] {
            entries.first { $0.configName == name }?.bindings.map { $0.combo.describe() } ?? ["missing"]
        }
        XCTAssertEqual(keys("move-column-left"), ["Alt+Shift+H"])
        XCTAssertEqual(keys("move-column-right"), ["Alt+Shift+L"])
        XCTAssertEqual(keys("move-window-left"), [])
        XCTAssertEqual(keys("move-window-right"), [])
        XCTAssertEqual(keys("move-up"), ["Alt+Shift+K"])
        XCTAssertEqual(keys("move-down"), ["Alt+Shift+J"])
    }

    func testConfigOverrideReplacesDefaultOnSameCombo() {
        let entries = shortcutCatalog(configKeybindings: [(combo("Alt+H"), .focusRight)])
        let left = entries.first { $0.configName == "focus-left" }!
        let right = entries.first { $0.configName == "focus-right" }!
        XCTAssertFalse(left.bindings.contains { $0.combo == combo("Alt+H") })
        XCTAssertTrue(right.bindings.contains { $0.combo == combo("Alt+H") && $0.source == .config })
        XCTAssertTrue(right.bindings.contains { $0.combo == combo("Alt+L") && $0.source == .default })
    }

    func testConfigAddsExtraBindingAndLastOneWins() {
        let entries = shortcutCatalog(
            configKeybindings: [(combo("Ctrl+H"), .focusLeft), (combo("Ctrl+H"), .moveLeft)]
        )
        let focus = entries.first { $0.configName == "focus-left" }!
        let move = entries.first { $0.configName == "move-window-left" }!
        XCTAssertFalse(focus.bindings.contains { $0.combo == combo("Ctrl+H") })
        XCTAssertTrue(move.bindings.contains { $0.combo == combo("Ctrl+H") && $0.source == .config })
    }

    func testLauncherShortcutIsListedAsAppEntryWithoutConfigName() {
        let launcher = shortcutCatalog(configKeybindings: []).first { $0.category == .app }
        XCTAssertNil(launcher?.configName)
        XCTAssertEqual(launcher?.bindings.map(\.combo), [combo("Alt+Space")])
    }

    func testKeycapsUseMacSymbolsInCanonicalOrder() {
        XCTAssertEqual(keycaps(for: combo("Alt+Shift+H")), ["⌥", "⇧", "H"])
        XCTAssertEqual(keycaps(for: combo("Ctrl+Alt+Shift+Cmd+F")), ["⌃", "⌥", "⇧", "⌘", "F"])
        XCTAssertEqual(keycaps(for: combo("Alt+Minus")), ["⌥", "-"])
        XCTAssertEqual(keycaps(for: combo("Alt+BracketLeft")), ["⌥", "["])
        XCTAssertEqual(keycaps(for: combo("Alt+Shift+Space")), ["⌥", "⇧", "Space"])
    }

    func testSearchMatchesNameSummaryConfigNameAndKeys() {
        let entries = shortcutCatalog(configKeybindings: [])
        XCTAssertEqual(filterShortcuts(entries, query: "").count, entries.count)
        XCTAssertTrue(filterShortcuts(entries, query: "center").contains { $0.configName == "center-column" })
        XCTAssertTrue(filterShortcuts(entries, query: "FOCUS-LEFT").contains { $0.configName == "focus-left" })
        XCTAssertTrue(filterShortcuts(entries, query: "alt+shift+h").contains { $0.configName == "move-column-left" })
        XCTAssertTrue(filterShortcuts(entries, query: "zzzzqq").isEmpty)
    }
}
