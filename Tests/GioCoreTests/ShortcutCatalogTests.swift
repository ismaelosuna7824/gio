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
            ["Focus", "Move", "Columns", "Windows", "Workspaces", "App"]
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
