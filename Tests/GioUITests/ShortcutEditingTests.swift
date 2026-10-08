import Foundation
import GioCore
import XCTest
@testable import GioUI

/// DA-07: editable Shortcuts rows, the recorder, the hotkey suspension
/// around it and the Logs "Log file level" picker.
@MainActor
final class ShortcutEditingTests: XCTestCase {
    private func combo(_ text: String) -> HotkeyCombo { parseHotkey(text)! }

    private func row(_ id: String, _ config: GioConfig = GioConfig()) -> ShortcutRowModel {
        let entries = shortcutCatalog(configKeybindings: config.keybindings, unbound: config.unboundKeys)
        return shortcutRowModel(entries.first { $0.id == id }!, config: config)
    }

    private func entry(_ id: String) -> ShortcutEntry {
        shortcutCatalog(configKeybindings: []).first { $0.id == id }!
    }

    // MARK: - Rows

    func testDefaultRowShowsItsKeysAndCannotReset() {
        let focusLeft = row("focus-left")
        XCTAssertEqual(focusLeft.bindings.map(\.combo), [combo("Alt+H")])
        XCTAssertEqual(focusLeft.bindings.map(\.source), [.default])
        XCTAssertTrue(focusLeft.isEditable)
        XCTAssertFalse(focusLeft.isCustomized)
        XCTAssertFalse(focusLeft.canReset)
        XCTAssertTrue(focusLeft.workspaceChoices.isEmpty)
    }

    func testConfigBindingsAndRemovedDefaultsShowWithTheirSourcesAndOfferReset() {
        let config = GioConfig(keybindings: [(combo("Ctrl+H"), .focusLeft)], unboundKeys: [combo("Alt+H")])
        let focusLeft = row("focus-left", config)
        XCTAssertEqual(focusLeft.bindings.map(\.combo), [combo("Ctrl+H")])
        XCTAssertEqual(focusLeft.bindings.map(\.source), [.config])
        XCTAssertEqual(focusLeft.removed, [combo("Alt+H")])
        XCTAssertTrue(focusLeft.isCustomized)
        XCTAssertTrue(focusLeft.canReset)
        XCTAssertEqual(focusLeft.bindings.first?.help, "⌃H · set in config.toml")
        XCTAssertEqual(row("focus-right", config).bindings.first?.help, "⌥L · default")
    }

    func testRemovingOnlyADefaultStillOffersReset() {
        let config = GioConfig(unboundKeys: [combo("Alt+C")])
        let center = row("center-column", config)
        XCTAssertTrue(center.bindings.isEmpty)
        XCTAssertEqual(center.removed, [combo("Alt+C")])
        XCTAssertTrue(center.canReset)
    }

    func testLauncherRowIsReadOnlyAndWorkspaceRowsPickANumber() {
        XCTAssertFalse(row("launcher").isEditable)
        XCTAssertFalse(row("launcher").canReset)
        let workspace = row("workspace N")
        XCTAssertEqual(workspace.workspaceChoices, Array(1...9))
        XCTAssertTrue(workspace.isRange)
        XCTAssertFalse(row("focus-left").isRange)
    }

    // MARK: - Recorder

    func testRecorderPromptsUntilAKeyIsPressed() throws {
        let recorder = try XCTUnwrap(ShortcutRecorder(entry: entry("center-column")))
        XCTAssertEqual(recorder.message, "Press the new shortcut. Esc cancels.")
        XCTAssertNil(recorder.saveTitle)
        XCTAssertTrue(recorder.edits.isEmpty)
        XCTAssertNil(ShortcutRecorder(entry: entry("launcher")))
    }

    func testFreeComboCanBeAdded() throws {
        var recorder = try XCTUnwrap(ShortcutRecorder(entry: entry("center-column")))
        recorder.record(combo("Ctrl+Alt+F9"), config: GioConfig())
        XCTAssertEqual(recorder.saveTitle, "Add")
        XCTAssertEqual(recorder.tone, .ok)
        XCTAssertEqual(recorder.edits, [.setKeybinding(combo("Ctrl+Alt+F9"), .action(.centerColumn))])
    }

    func testConflictNamesTheOtherActionAndOffersReplace() throws {
        var recorder = try XCTUnwrap(ShortcutRecorder(entry: entry("focus-left")))
        recorder.record(combo("Alt+L"), config: GioConfig())
        XCTAssertEqual(recorder.message, "⌥L already runs Focus right (default). Replace moves it to Focus left.")
        XCTAssertEqual(recorder.saveTitle, "Replace")
        XCTAssertEqual(recorder.tone, .warning)
        XCTAssertEqual(recorder.edits, [.setKeybinding(combo("Alt+L"), .action(.focusLeft))])

        let config = GioConfig(keybindings: [(combo("Ctrl+F9"), .centerColumn)])
        recorder.record(combo("Ctrl+F9"), config: config)
        XCTAssertEqual(recorder.message, "⌃F9 already runs Center column (set in config.toml). Replace moves it to Focus left.")
    }

    func testInvalidCombosExplainWhyAndCannotBeSaved() throws {
        var recorder = try XCTUnwrap(ShortcutRecorder(entry: entry("focus-left")))
        recorder.record(HotkeyCombo(modifiers: [], key: "H"), config: GioConfig())
        XCTAssertEqual(recorder.message, "Add at least one modifier (⌃ ⌥ ⇧ ⌘) so the key still types normally.")
        XCTAssertNil(recorder.saveTitle)
        XCTAssertEqual(recorder.tone, .error)
        recorder.record(launcherHotkey, config: GioConfig())
        XCTAssertEqual(recorder.message, "⌥Space opens the launcher and cannot be rebound.")
        recorder.record(HotkeyCombo(modifiers: [.alt], key: "§"), config: GioConfig())
        XCTAssertEqual(recorder.message, "§ cannot be bound. Use a letter, digit, F1–F12, an arrow or a punctuation key.")
        recorder.record(combo("Alt+H"), config: GioConfig())
        XCTAssertEqual(recorder.message, "⌥H already runs Focus left.")
        XCTAssertNil(recorder.saveTitle)
        XCTAssertTrue(recorder.edits.isEmpty)
    }

    func testWorkspaceRecorderBindsTheChosenNumber() throws {
        var recorder = try XCTUnwrap(ShortcutRecorder(entry: entry("workspace N")))
        XCTAssertEqual(recorder.workspace, 1)
        recorder.choose(workspace: 4, config: GioConfig())
        recorder.record(combo("Ctrl+4"), config: GioConfig())
        XCTAssertEqual(recorder.edits, [.setKeybinding(combo("Ctrl+4"), .action(.workspace(4)))])
        // Alt+4 is workspace 4's own default; for workspace 5 it is a conflict.
        recorder.record(combo("Alt+4"), config: GioConfig())
        XCTAssertEqual(recorder.message, "⌥4 already runs Go to workspace 4.")
        recorder.choose(workspace: 5, config: GioConfig())
        XCTAssertEqual(recorder.saveTitle, "Replace")
    }

    func testBareEscapeCancelsAndModifiedEscapeIsACombo() {
        XCTAssertEqual(recorderKey(HotkeyCombo(modifiers: [], key: "Escape")), .cancel)
        XCTAssertEqual(recorderKey(combo("Alt+Escape")), .capture(combo("Alt+Escape")))
        XCTAssertEqual(recorderKey(combo("Alt+H")), .capture(combo("Alt+H")))
    }

    // MARK: - Row edits

    func testRemoveAndResetEditsComeFromCore() {
        let config = GioConfig(keybindings: [(combo("Ctrl+H"), .focusLeft)], unboundKeys: [combo("Alt+H")])
        XCTAssertEqual(row("focus-left", config).resetEdits, [.removeKeybinding(combo("Alt+H")), .removeKeybinding(combo("Ctrl+H"))])
        XCTAssertEqual(row("focus-left", config).removeEdits(combo("Ctrl+H")), [.removeKeybinding(combo("Ctrl+H"))])
        XCTAssertEqual(row("focus-right").removeEdits(combo("Alt+L")), [.setKeybinding(combo("Alt+L"), .none)])
    }

    func testRowEditToastsSayWhatChanged() {
        XCTAssertEqual(
            ApplyToast(feedback: .applied(warnings: []), successTitle: "Added ⌥⇧X to Center column"),
            ApplyToast(kind: .success, title: "Added ⌥⇧X to Center column", details: [])
        )
        XCTAssertEqual(ApplyToast(feedback: .rejected(messages: ["bad"]), successTitle: "x").kind, .failure)
        XCTAssertEqual(ApplyToast(feedback: .applied(warnings: ["w"]), successTitle: "x").kind, .warning)
        var recorder = ShortcutRecorder(entry: entry("focus-left"))!
        recorder.record(combo("Alt+L"), config: GioConfig())
        XCTAssertEqual(recorder.savedTitle, "Moved ⌥L to Focus left")
        recorder.record(combo("Ctrl+Alt+F9"), config: GioConfig())
        XCTAssertEqual(recorder.savedTitle, "Added ⌃⌥F9 to Focus left")
    }

    // MARK: - Suspension

    private final class Recorded: @unchecked Sendable {
        var calls: [Bool] = []
    }

    private func model(_ recorded: Recorded) -> DesktopModel {
        DesktopModel(fetch: { SessionSnapshot() }, actions: DesktopActions(
            applyEdits: { _ in .failure(ConfigErrors(messages: ["unused"])) },
            setHotkeysSuspended: { recorded.calls.append($0) }
        ))
    }

    func testRecordingSuspendsHotkeysAndCancelResumesOnce() {
        let recorded = Recorded()
        let model = model(recorded)
        model.suspendHotkeys()
        XCTAssertTrue(model.hotkeysSuspended)
        model.resumeHotkeys()
        model.resumeHotkeys()
        XCTAssertFalse(model.hotkeysSuspended)
        XCTAssertEqual(recorded.calls, [true, false])
    }

    func testHidingTheWindowNeverLeavesHotkeysOff() {
        let recorded = Recorded()
        let model = model(recorded)
        model.suspendHotkeys()
        model.setWindowVisible(false)
        XCTAssertFalse(model.hotkeysSuspended)
        XCTAssertEqual(recorded.calls, [true, false])
        model.setWindowVisible(true)
        XCTAssertEqual(recorded.calls, [true, false])
    }

    // MARK: - Log file level

    func testLogFileLevelOptionsAndEdits() {
        XCTAssertEqual(logFileLevelOptions.map(\.level), [.trace, .debug, .info, .warn, .error])
        XCTAssertEqual(logFileLevelOptions.map(\.title), ["Trace", "Debug", "Info", "Warning", "Error"])
        XCTAssertTrue(logFileLevelEdits(current: .info, chosen: .info).isEmpty)
        XCTAssertEqual(
            logFileLevelEdits(current: .info, chosen: .debug),
            [.set(table: "logging", key: "level", value: .string("debug"))]
        )
        XCTAssertEqual(
            logFileLevelToast(.applied(warnings: []), level: .debug),
            ApplyToast(kind: .success, title: "gio.log now records Debug and above", details: [])
        )
        XCTAssertEqual(logFileLevelToast(.rejected(messages: ["bad"]), level: .debug).kind, .failure)
    }
}
