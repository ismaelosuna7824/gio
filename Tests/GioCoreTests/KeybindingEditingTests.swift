import XCTest
@testable import GioCore

/// DA-07: key bindings edited from the app. The `"none"` unbind value,
/// routing with hotkeys suspended, recorder validation, the pure edit lists
/// and the catalog sources.
final class KeybindingEditingTests: XCTestCase {
    private func combo(_ text: String) -> HotkeyCombo { parseHotkey(text)! }

    private func parse(_ text: String) throws -> GioConfig {
        switch parseGioConfig(text) {
        case .success(let (config, _)):
            return config
        case .failure(let errors):
            XCTFail("parse failed: \(errors.messages)")
            throw errors
        }
    }

    private func patched(_ text: String, _ edits: [ConfigEdit]) throws -> PatchedConfig {
        switch patchGioConfig(text, edits: edits) {
        case .success(let value):
            return value
        case .failure(let errors):
            XCTFail("patch failed: \(errors.messages)")
            throw errors
        }
    }

    // MARK: - "none"

    func testNoneUnbindsADefaultComboAndLeavesTheOthers() throws {
        let config = try parse("[keybindings]\n\"Alt+H\" = \"none\"\n")
        XCTAssertEqual(config.unboundKeys, [combo("Alt+H")])
        XCTAssertTrue(config.keybindings.isEmpty)
        let dispatcher = config.makeDispatcher()
        XCTAssertNil(dispatcher.action(for: combo("Alt+H")))
        XCTAssertEqual(dispatcher.action(for: combo("Alt+L")), .focusRight)
        XCTAssertEqual(dispatcher.action(for: combo("Alt+Shift+H")), .consumeOrExpelLeft)
        XCTAssertEqual(dispatcher.bindingCount, defaultHotkeyBindings().count - 1)
    }

    func testTheLaterLineWinsBetweenNoneAndAnAction() throws {
        let unbound = try parse("[keybindings]\n\"Alt+H\" = \"center-column\"\n\"Alt+H\" = \"none\"\n")
        XCTAssertNil(unbound.makeDispatcher().action(for: combo("Alt+H")))
        XCTAssertTrue(unbound.keybindings.isEmpty)
        XCTAssertEqual(unbound.unboundKeys, [combo("Alt+H")])

        let rebound = try parse("[keybindings]\n\"Alt+H\" = \"none\"\n\"Alt+H\" = \"center-column\"\n")
        XCTAssertEqual(rebound.makeDispatcher().action(for: combo("Alt+H")), .centerColumn)
        XCTAssertTrue(rebound.unboundKeys.isEmpty)
    }

    func testNoneOnAComboWithoutDefaultIsAccepted() throws {
        let config = try parse("[keybindings]\n\"Ctrl+F9\" = \"none\"\n")
        XCTAssertNil(config.makeDispatcher().action(for: combo("Ctrl+F9")))
        XCTAssertEqual(config.makeDispatcher().bindingCount, defaultHotkeyBindings().count)
    }

    func testUnknownActionMessageMentionsNone() {
        guard case .failure(let errors) = parseGioConfig("[keybindings]\n\"Alt+H\" = \"fly\"\n") else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(errors.messages.joined().contains("\"none\""), errors.messages.joined())
    }

    // MARK: - Routing and suspension

    func testRoutingSendsLauncherOverviewAndActions() {
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(routeHotkey(launcherHotkey, dispatcher: dispatcher, suspended: false), .launcher)
        XCTAssertEqual(routeHotkey(combo("Alt+O"), dispatcher: dispatcher, suspended: false), .overview)
        XCTAssertEqual(routeHotkey(combo("Alt+H"), dispatcher: dispatcher, suspended: false), .action(.focusLeft))
        XCTAssertEqual(routeHotkey(combo("Ctrl+F9"), dispatcher: dispatcher, suspended: false), .passThrough)
    }

    func testSuspendedRoutingPassesEveryComboThrough() {
        let dispatcher = HotkeyDispatcher()
        for text in ["Alt+Space", "Alt+O", "Alt+H", "Ctrl+Alt+Shift+L"] {
            XCTAssertEqual(routeHotkey(combo(text), dispatcher: dispatcher, suspended: true), .passThrough, text)
        }
    }

    func testGateSuspendsAndResumesIdempotently() {
        let gate = HotkeyGate()
        XCTAssertFalse(gate.isSuspended)
        gate.setSuspended(true)
        gate.setSuspended(true)
        XCTAssertTrue(gate.isSuspended)
        gate.setSuspended(false)
        XCTAssertFalse(gate.isSuspended)
        gate.setSuspended(false)
        XCTAssertFalse(gate.isSuspended)
    }

    // MARK: - Validation

    func testComboNeedsAModifier() {
        XCTAssertEqual(
            checkShortcut(HotkeyCombo(modifiers: [], key: "H"), for: .focusLeft, config: GioConfig()),
            .invalid(.noModifier)
        )
    }

    func testKeyMustBeInTheVocabulary() {
        XCTAssertEqual(
            checkShortcut(HotkeyCombo(modifiers: [.alt], key: "§"), for: .focusLeft, config: GioConfig()),
            .invalid(.unsupportedKey("§"))
        )
    }

    func testAltSpaceIsReservedForTheLauncher() {
        XCTAssertEqual(
            checkShortcut(launcherHotkey, for: .centerColumn, config: GioConfig()),
            .invalid(.reservedForLauncher)
        )
    }

    func testFreeComboAndComboTheActionAlreadyHas() {
        XCTAssertEqual(checkShortcut(combo("Ctrl+Alt+F9"), for: .centerColumn, config: GioConfig()), .free)
        XCTAssertEqual(checkShortcut(combo("Alt+H"), for: .focusLeft, config: GioConfig()), .alreadyBound)
    }

    func testConflictNamesTheOtherActionAndWhereItsBindingComesFrom() {
        XCTAssertEqual(
            checkShortcut(combo("Alt+L"), for: .focusLeft, config: GioConfig()),
            .conflict(action: .focusRight, source: .default)
        )
        let config = GioConfig(keybindings: [(combo("Ctrl+F9"), .centerColumn)])
        XCTAssertEqual(
            checkShortcut(combo("Ctrl+F9"), for: .focusLeft, config: config),
            .conflict(action: .centerColumn, source: .config)
        )
    }

    func testAComboSetToNoneIsFree() {
        let config = GioConfig(unboundKeys: [combo("Alt+H")])
        XCTAssertEqual(checkShortcut(combo("Alt+H"), for: .centerColumn, config: config), .free)
    }

    // MARK: - Edit lists

    func testAddWritesOneBindingLine() {
        XCTAssertEqual(
            addShortcutEdits(combo("Ctrl+Alt+F9"), action: .centerColumn),
            [.setKeybinding(combo("Ctrl+Alt+F9"), .action(.centerColumn))]
        )
    }

    func testReplaceMovesTheComboAwayFromTheOtherAction() throws {
        let result = try patched("[keybindings]\n", addShortcutEdits(combo("Alt+L"), action: .focusLeft))
        XCTAssertEqual(result.config.makeDispatcher().action(for: combo("Alt+L")), .focusLeft)
        let entries = shortcutCatalog(configKeybindings: result.config.keybindings, unbound: result.config.unboundKeys)
        let right = try XCTUnwrap(entries.first { $0.id == "focus-right" })
        XCTAssertFalse(right.bindings.contains { $0.combo == combo("Alt+L") })
        let left = try XCTUnwrap(entries.first { $0.id == "focus-left" })
        XCTAssertTrue(left.bindings.contains(ShortcutBinding(combo: combo("Alt+L"), source: .config)))
    }

    func testRemovingAConfigOnlyBindingDeletesItsLine() {
        XCTAssertEqual(removeShortcutEdits(combo("Ctrl+F9")), [.removeKeybinding(combo("Ctrl+F9"))])
    }

    func testRemovingADefaultOrAnOverrideOfADefaultComboWritesNone() throws {
        XCTAssertEqual(removeShortcutEdits(combo("Alt+H")), [.setKeybinding(combo("Alt+H"), .none)])
        // Deleting the override line would bring focus-left back on Alt+H.
        let result = try patched("[keybindings]\n\"Alt+H\" = \"center-column\"\n", removeShortcutEdits(combo("Alt+H")))
        XCTAssertEqual(result.text, "[keybindings]\n\"Alt+H\" = \"none\"\n")
        XCTAssertNil(result.config.makeDispatcher().action(for: combo("Alt+H")))
    }

    func testResetRemovesEveryConfigLineTouchingTheFamily() {
        let config = GioConfig(
            keybindings: [(combo("Ctrl+H"), .focusLeft), (combo("Alt+L"), .centerColumn), (combo("Ctrl+F9"), .focusRight)],
            unboundKeys: [combo("Alt+H"), combo("Alt+K")]
        )
        // Ctrl+H binds focus-left, Alt+H was its default (set to none);
        // Alt+L and Ctrl+F9 belong to other families, Alt+K to focus-up.
        XCTAssertEqual(
            resetShortcutEdits(family: "focus-left", config: config),
            [.removeKeybinding(combo("Alt+H")), .removeKeybinding(combo("Ctrl+H"))]
        )
        // focus-right lost its default Alt+L to another action and has Ctrl+F9.
        XCTAssertEqual(
            resetShortcutEdits(family: "focus-right", config: config),
            [.removeKeybinding(combo("Alt+L")), .removeKeybinding(combo("Ctrl+F9"))]
        )
        XCTAssertTrue(resetShortcutEdits(family: "center-column", config: GioConfig()).isEmpty)
    }

    func testResetCoversEveryNumberOfAWorkspaceFamily() {
        let config = GioConfig(keybindings: [(combo("Ctrl+3"), .workspace(3))], unboundKeys: [combo("Alt+5")])
        XCTAssertEqual(
            resetShortcutEdits(family: "workspace N", config: config),
            [.removeKeybinding(combo("Alt+5")), .removeKeybinding(combo("Ctrl+3"))]
        )
    }

    func testResetEditsRestoreTheDefaults() throws {
        let text = "[keybindings]\n\"Alt+H\" = \"none\"\n\"Ctrl+H\" = \"focus-left\"\n"
        let config = try parse(text)
        let result = try patched(text, resetShortcutEdits(family: "focus-left", config: config))
        XCTAssertEqual(result.text, "[keybindings]\n")
        XCTAssertEqual(result.config.makeDispatcher().action(for: combo("Alt+H")), .focusLeft)
    }

    func testLogLevelEditWritesTheLoggingTable() throws {
        XCTAssertEqual(logLevelEdits(.debug), [.set(table: "logging", key: "level", value: .string("debug"))])
        let result = try patched("[logging]\nlevel = \"info\"  # quiet\n", logLevelEdits(.warn))
        XCTAssertEqual(result.text, "[logging]\nlevel = \"warn\"  # quiet\n")
        XCTAssertEqual(result.config.logging.level, .warn)
    }

    // MARK: - Patcher

    func testSetKeybindingAppendsAQuotedLineAfterTheLastBinding() throws {
        let text = "[keybindings]\n\"Alt+H\" = \"focus-left\"\n# Also available: ...\n\n[layout]\ngaps = 8\n"
        let result = try patched(text, [.setKeybinding(combo("Ctrl+Alt+F9"), .action(.centerColumn))])
        XCTAssertEqual(
            result.text,
            "[keybindings]\n\"Alt+H\" = \"focus-left\"\n\"Ctrl+Alt+F9\" = \"center-column\"\n# Also available: ...\n\n[layout]\ngaps = 8\n"
        )
    }

    func testSetKeybindingRewritesTheMatchingLineWhateverItsSpelling() throws {
        let text = "[keybindings]\n\"shift+option+h\" = \"focus-left\"  # mine\n\"Alt+Shift+H\" = \"center-column\"\n"
        let result = try patched(text, [.setKeybinding(combo("Alt+Shift+H"), .none)])
        XCTAssertEqual(result.text, "[keybindings]\n\"shift+option+h\" = \"none\"  # mine\n")
        XCTAssertEqual(result.config.unboundKeys, [combo("Alt+Shift+H")])
    }

    func testSetKeybindingCreatesTheTable() throws {
        let result = try patched("[layout]\ngaps = 8\n", [.setKeybinding(combo("Ctrl+3"), .action(.workspace(3)))])
        XCTAssertEqual(result.text, "[layout]\ngaps = 8\n\n[keybindings]\n\"Ctrl+3\" = \"workspace 3\"\n")
        XCTAssertEqual(result.config.makeDispatcher().action(for: combo("Ctrl+3")), .workspace(3))
    }

    func testRemoveKeybindingDeletesEveryLineForTheComboAndKeepsComments() throws {
        let text = "[keybindings]\n# mine\n\"Alt+H\" = \"focus-left\"\n\"alt+h\" = \"center-column\"\n\"Alt+L\" = \"focus-right\"\n"
        let result = try patched(text, [.removeKeybinding(combo("Alt+H"))])
        XCTAssertEqual(result.text, "[keybindings]\n# mine\n\"Alt+L\" = \"focus-right\"\n")
    }

    // MARK: - Catalog

    func testCatalogMarksConfigBindingsAndRemovedDefaults() throws {
        let entries = shortcutCatalog(configKeybindings: [(combo("Ctrl+H"), .focusLeft)], unbound: [combo("Alt+H")])
        let left = try XCTUnwrap(entries.first { $0.id == "focus-left" })
        XCTAssertEqual(left.bindings, [ShortcutBinding(combo: combo("Ctrl+H"), source: .config)])
        XCTAssertEqual(left.removedDefaults, [combo("Alt+H")])
        let right = try XCTUnwrap(entries.first { $0.id == "focus-right" })
        XCTAssertEqual(right.bindings, [ShortcutBinding(combo: combo("Alt+L"), source: .default)])
        XCTAssertTrue(right.removedDefaults.isEmpty)
    }

    func testEntriesCarryTheirRepresentativeAction() {
        let entries = shortcutCatalog(configKeybindings: [])
        XCTAssertEqual(entries.first { $0.id == "focus-left" }?.action, .focusLeft)
        XCTAssertEqual(entries.first { $0.id == "workspace N" }?.action, .workspace(1))
        XCTAssertNil(entries.first { $0.id == "launcher" }?.action)
    }

    func testConfigActionNamesRoundTrip() {
        XCTAssertEqual(configActionName(.workspace(3)), "workspace 3")
        XCTAssertEqual(configActionName(.moveToWorkspace(2)), "move-to-workspace 2")
        XCTAssertEqual(configActionName(.focusMonitor(.left)), "focus-monitor-left")
        for (_, action) in defaultHotkeyBindings() {
            XCTAssertEqual(parseActionName(configActionName(action)), action, configActionName(action))
        }
        XCTAssertEqual(shortcutActionTitle(.workspace(3)), "Go to workspace 3")
        XCTAssertEqual(shortcutActionTitle(.focusRight), "Focus right")
    }
}
