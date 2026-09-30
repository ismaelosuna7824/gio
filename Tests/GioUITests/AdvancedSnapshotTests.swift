import Foundation
import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of DD-04 Shortcuts, Logs and Diagnostics (opt-in, see
/// `SnapshotHarness`). Pages render statically (no `ScrollView`).
@MainActor
final class AdvancedSnapshotTests: XCTestCase {
    private func page<V: View>(_ view: V) -> some View {
        view
            .environment(\.gioStaticPage, true)
            .environment(\.gioAccent, FocusRingSectionConfig.defaultColor)
    }

    private func model(keybindings: [(HotkeyCombo, HotkeyAction)] = []) -> DesktopModel {
        DesktopModel(fetch: {
            SessionSnapshot(
                keybindings: keybindings,
                facts: OverviewFixture.facts(accessibility: true, screenRecording: true),
                config: GioConfig()
            )
        })
    }

    private let overrides: [(HotkeyCombo, HotkeyAction)] = [
        (HotkeyCombo(modifiers: [.ctrl, .alt], key: "h"), .focusLeft),
    ]

    func testShortcutsList() throws {
        try SnapshotHarness.render("dd04-shortcuts", size: CGSize(width: 820, height: 1500)) {
            page(ShortcutsView(model: model(keybindings: overrides)))
        }
    }

    func testShortcutsFilteredCheatSheet() throws {
        try SnapshotHarness.render("dd04-shortcuts-cheatsheet", size: CGSize(width: 820, height: 1260)) {
            page(ShortcutsView(model: model(keybindings: overrides), cheatSheet: true))
        }
    }

    func testShortcutsSearchCategory() throws {
        try SnapshotHarness.render("dd04-shortcuts-search", size: CGSize(width: 820, height: 520)) {
            page(ShortcutsView(model: model(), query: "column", chip: .category(.columns)))
        }
    }

    func testShortcutsEmpty() throws {
        try SnapshotHarness.render("dd04-shortcuts-empty", size: CGSize(width: 820, height: 520)) {
            page(ShortcutsView(model: model(), query: "teleport", chip: .category(.focus)))
        }
    }

    private static let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!

    private static func line(_ secondsAgo: Int, _ level: LogLevel, _ message: String) -> LogEntry {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(secondsAgo)))
        return LogEntry(timestamp: stamp, level: level, message: message)
    }

    static let logFixture: [LogEntry] = [
        line(7200, .info, "session start version=0.1.0 displays=1 windows=9"),
        line(3700, .debug, "reconcile writes=4 skipped=2 took=3ms"),
        line(900, .info, "config reloaded gaps=8 padding=8 presets=3"),
        line(600, .warn, "slow frame 41ms app=Xcode pid=812 element=4411"),
        line(420, .info, "focus column=2 workspace=2 window=812:4411"),
        line(400, .info, "anim done windows=7 frames=139 dropped=0 duration=1196ms curve=spring"),
        line(399, .info, "anim done windows=7 frames=139 dropped=0 duration=1196ms curve=spring"),
        line(398, .info, "anim done windows=7 frames=139 dropped=0 duration=1196ms curve=spring"),
        line(120, .error, "AX set frame failed pid=733 element=129 code=-25204"),
        line(90, .info, "workspace switch 2 -> 3 prepositioned=4"),
        line(40, .trace, "tap key=h mods=alt"),
        line(12, .info, "restore applied=9 vanished=0 failed=0"),
        line(2, .warn, "config line 14: unknown key 'gap' (did you mean 'gaps'?)"),
    ]

    func testLogs() throws {
        try SnapshotHarness.render("dd04-logs", size: CGSize(width: 820, height: 620)) {
            page(LogsView(model: model(), seed: Self.logFixture, now: Self.now))
        }
    }

    func testLogsPausedFiltered() throws {
        var filter = LogLevelFilter(levels: [.warn, .error])
        filter.search = ""
        try SnapshotHarness.render("dd04-logs-paused", size: CGSize(width: 820, height: 420)) {
            page(LogsView(model: model(), seed: Self.logFixture, now: Self.now, paused: true, filter: filter))
        }
    }

    func testDiagnosticsHealthy() throws {
        try SnapshotHarness.render("dd04-diagnostics", size: CGSize(width: 820, height: 760)) {
            page(DiagnosticsPage(
                facts: OverviewFixture.facts(accessibility: true, screenRecording: true), config: GioConfig(),
                toast: ApplyToast(kind: .success, title: "Config reloaded", details: [])
            ))
        }
    }

    func testDiagnosticsProblemsWithMeasurement() throws {
        var config = GioConfig()
        config.animations.renderer = .snapshot
        let base = OverviewFixture.facts(accessibility: false, screenRecording: true)
        let facts = SessionFacts(
            configPath: base.configPath, configExists: true,
            configMessages: ["line 14: unknown key 'gap'", "line 22: width must be a number"],
            accessibilityGranted: false, currentWorkspace: 2, displays: base.displays, windows: base.windows,
            screenRecordingGranted: true, strip: base.strip
        )
        try SnapshotHarness.render("dd04-diagnostics-problems", size: CGSize(width: 820, height: 1000)) {
            page(DiagnosticsPage(
                facts: facts, config: config,
                measurement: "snapshot capture windows=7 displays=1 captured=7 failed=0 total=84ms\nper-window p50=9ms p95=21ms max=24ms\nwallpaper 12ms · first frame 31ms"
            ))
        }
    }
}
