import Foundation
import GioCore
import XCTest
@testable import GioUI

/// DD-04: pure pieces behind Shortcuts (chips, sections), Logs (level
/// filter, repeat grouping, relative times) and Diagnostics (checklist).
final class AdvancedPresentationTests: XCTestCase {
    // MARK: - Shortcuts

    private let catalog = shortcutCatalog(configKeybindings: [])

    func testAllChipKeepsCategoryOrder() {
        let sections = shortcutSections(catalog, chip: .all, query: "")
        XCTAssertEqual(sections.map(\.category), ShortcutCategory.allCases)
        XCTAssertEqual(sections.flatMap(\.entries).count, catalog.count)
    }

    func testCategoryChipShowsOneSection() {
        let sections = shortcutSections(catalog, chip: .category(.columns), query: "")
        XCTAssertEqual(sections.map(\.category), [.columns])
        XCTAssertTrue(sections[0].entries.allSatisfy { $0.category == .columns })
    }

    func testQueryAndChipCombineAndEmptySectionsDrop() {
        let sections = shortcutSections(catalog, chip: .all, query: "workspace")
        XCTAssertFalse(sections.isEmpty)
        XCTAssertFalse(sections.contains { $0.entries.isEmpty })
        XCTAssertTrue(shortcutSections(catalog, chip: .category(.focus), query: "launcher").isEmpty)
    }

    func testChipsAndCountsFollowTheQuery() {
        XCTAssertEqual(ShortcutChip.all.title, "All")
        XCTAssertEqual(ShortcutChip.allChips.first, .all)
        XCTAssertEqual(ShortcutChip.allChips.count, ShortcutCategory.allCases.count + 1)
        XCTAssertEqual(shortcutChipCount(catalog, chip: .all, query: ""), catalog.count)
        XCTAssertEqual(shortcutChipCount(catalog, chip: .category(.app), query: ""), 1)
        XCTAssertEqual(shortcutChipCount(catalog, chip: .category(.app), query: "zzz"), 0)
    }

    func testOverriddenWhenAConfigBindingExists() {
        let overridden = shortcutCatalog(configKeybindings: [
            (HotkeyCombo(modifiers: [.ctrl], key: "h"), .focusLeft),
        ])
        let focusLeft = overridden.first { $0.id == "focus-left" }!
        XCTAssertTrue(isOverridden(focusLeft))
        XCTAssertFalse(isOverridden(catalog.first { $0.id == "focus-left" }!))
    }

    // MARK: - Logs

    private func entry(_ level: LogLevel, _ message: String, _ time: String = "2026-09-30T02:19:54Z") -> LogEntry {
        LogEntry(timestamp: time, level: level, message: message)
    }

    func testRepeatedConsecutiveLinesCollapse() {
        let groups = groupLogEntries([
            entry(.info, "a", "2026-09-30T02:19:50Z"),
            entry(.info, "a", "2026-09-30T02:19:51Z"),
            entry(.info, "a", "2026-09-30T02:19:52Z"),
            entry(.warn, "a"),
            entry(.info, "b"),
            entry(.info, "a"),
        ])
        XCTAssertEqual(groups.map(\.count), [3, 1, 1, 1])
        XCTAssertEqual(groups.map(\.message), ["a", "a", "b", "a"])
        XCTAssertEqual(groups[0].firstTimestamp, "2026-09-30T02:19:50Z")
        XCTAssertEqual(groups[0].lastTimestamp, "2026-09-30T02:19:52Z")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertTrue(groupLogEntries([]).isEmpty)
    }

    func testLevelChipsFilterAndSearch() {
        let entries = [entry(.debug, "tick"), entry(.info, "reload ok"), entry(.warn, "slow frame"), entry(.error, "AX failed")]
        var filter = LogLevelFilter()
        XCTAssertEqual(filter.levels, [.info, .warn, .error])
        XCTAssertEqual(filter.apply(to: entries).map(\.message), ["reload ok", "slow frame", "AX failed"])
        filter.toggle(.info)
        XCTAssertEqual(filter.apply(to: entries).map(\.message), ["slow frame", "AX failed"])
        filter.toggle(.debug)
        filter.search = "TICK"
        XCTAssertEqual(filter.apply(to: entries).map(\.message), ["tick"])
    }

    func testLevelCounts() {
        let counts = logLevelCounts([entry(.info, "a"), entry(.info, "b"), entry(.error, "c")])
        XCTAssertEqual(counts[.info], 2)
        XCTAssertEqual(counts[.error], 1)
        XCTAssertNil(counts[.warn])
    }

    func testCopyTextMarksRepeats() {
        let groups = groupLogEntries([entry(.info, "a"), entry(.info, "a"), entry(.error, "b")])
        XCTAssertEqual(
            logCopyText(groups),
            "[2026-09-30T02:19:54Z] [INFO] a (×2)\n[2026-09-30T02:19:54Z] [ERROR] b"
        )
    }

    func testRelativeTimes() {
        let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        XCTAssertEqual(relativeLogTime("2026-09-30T11:59:58Z", now: now), "now")
        XCTAssertEqual(relativeLogTime("2026-09-30T11:59:30Z", now: now), "30s ago")
        XCTAssertEqual(relativeLogTime("2026-09-30T11:55:00Z", now: now), "5m ago")
        XCTAssertEqual(relativeLogTime("2026-09-30T09:00:00Z", now: now), "3h ago")
        XCTAssertEqual(relativeLogTime("2026-09-27T12:00:00Z", now: now), "3d ago")
        XCTAssertEqual(relativeLogTime("2026-09-30T12:00:30Z", now: now), "now")
        XCTAssertNil(relativeLogTime("yesterday", now: now))
    }

    // MARK: - Diagnostics

    private func facts(ax: Bool = true, sr: Bool = true, messages: [String] = [], exists: Bool = true, displays: Int = 1) -> SessionFacts {
        SessionFacts(
            configPath: "~/.config/gio/config.toml", configExists: exists, configMessages: messages,
            accessibilityGranted: ax, currentWorkspace: 2,
            displays: (0..<displays).map { DisplayFact(id: UInt32($0 + 1), workspace: 2) }, windows: [],
            screenRecordingGranted: sr
        )
    }

    private func checklist(_ facts: SessionFacts, config: GioConfig = GioConfig(), socket: Bool = true) -> [DiagnosticCheck] {
        diagnosticChecklist(
            facts: facts, config: config, version: "0.1.0", build: "7",
            socketPath: "/tmp/gio.sock", socketExists: socket, logPath: "/tmp/gio.log"
        )
    }

    private func check(_ list: [DiagnosticCheck], _ id: String) -> DiagnosticCheck {
        list.first { $0.id == id }!
    }

    func testChecklistHasTheSixCardsInOrder() {
        XCTAssertEqual(
            checklist(facts()).map(\.title),
            ["Permissions", "Session", "Configuration", "Displays", "Renderer", "Logging"]
        )
    }

    func testHealthySessionIsAllOk() {
        let list = checklist(facts())
        XCTAssertEqual(check(list, "permissions").status, .ok)
        XCTAssertEqual(check(list, "session").status, .ok)
        XCTAssertTrue(check(list, "session").details.contains("Version 0.1.0 (build 7)"))
        XCTAssertEqual(check(list, "configuration").badge, "Valid")
        XCTAssertEqual(check(list, "displays").badge, "1 display")
        XCTAssertEqual(check(list, "logging").details, ["/tmp/gio.log"])
    }

    func testMissingAccessibilityIsAnError() {
        let permissions = check(checklist(facts(ax: false)), "permissions")
        XCTAssertEqual(permissions.status, .error)
        XCTAssertEqual(permissions.badge, "Accessibility missing")
    }

    func testScreenRecordingOnlyMattersForTheSnapshotRenderer() {
        var config = GioConfig()
        config.animations.renderer = .ax
        XCTAssertEqual(check(checklist(facts(sr: false), config: config), "permissions").status, .ok)
        config.animations.renderer = .snapshot
        let list = checklist(facts(sr: false), config: config)
        XCTAssertEqual(check(list, "permissions").status, .warning)
        XCTAssertEqual(check(list, "renderer").status, .warning)
        XCTAssertEqual(check(checklist(facts(), config: config), "renderer").badge, "Snapshot")
    }

    func testConfigurationAndSocketProblems() {
        let list = checklist(facts(messages: ["line 3: bad", "line 9: bad"]), socket: false)
        XCTAssertEqual(check(list, "configuration").status, .warning)
        XCTAssertEqual(check(list, "configuration").badge, "2 issues")
        XCTAssertEqual(check(list, "configuration").details, ["line 3: bad", "line 9: bad"])
        XCTAssertEqual(check(list, "session").status, .error)
        XCTAssertEqual(check(checklist(facts(exists: false)), "configuration").badge, "Defaults")
        XCTAssertEqual(check(checklist(facts(displays: 2)), "displays").badge, "2 displays")
    }

    func testRendererOffWhenAnimationsAreDisabled() {
        var config = GioConfig()
        config.animations.enabled = false
        XCTAssertEqual(check(checklist(facts(), config: config), "renderer").badge, "Off")
    }

    func testSnapshotCaptureTestOnlyWithTheSnapshotRenderer() {
        var config = GioConfig()
        config.animations.renderer = .ax
        XCTAssertFalse(showsSnapshotCaptureTest(config: config, screenRecording: true))
        config.animations.renderer = .snapshot
        XCTAssertTrue(showsSnapshotCaptureTest(config: config, screenRecording: true))
        XCTAssertFalse(showsSnapshotCaptureTest(config: config, screenRecording: false))
        config.animations.enabled = false
        XCTAssertFalse(showsSnapshotCaptureTest(config: config, screenRecording: true))
    }
}

final class CompactBindingTests: XCTestCase {
    func testLongFamiliesShowFirstAndLast() {
        let workspace = shortcutCatalog(configKeybindings: []).first { $0.id == "workspace N" }!
        XCTAssertGreaterThan(workspace.bindings.count, 3)
        let compact = compactBindings(workspace.bindings)
        XCTAssertEqual(compact.shown, [workspace.bindings.first!, workspace.bindings.last!])
        XCTAssertTrue(compact.isRange)
    }

    func testShortListsStayWhole() {
        let entry = shortcutCatalog(configKeybindings: []).first { $0.id == "focus-left" }!
        let compact = compactBindings(entry.bindings)
        XCTAssertEqual(compact.shown, entry.bindings)
        XCTAssertFalse(compact.isRange)
        XCTAssertEqual(compactBindings([]).shown, [])
    }
}
