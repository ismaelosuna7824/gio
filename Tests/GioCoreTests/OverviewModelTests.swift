import XCTest
@testable import GioCore

final class OverviewModelTests: XCTestCase {
    private func fact(
        _ app: String, title: String = "doc", workspace: Int? = 1, mode: WindowMode = .tiled,
        reason: FloatReason? = nil, minimized: Bool = false, shown: Bool = true, id: String? = nil
    ) -> WindowFact {
        WindowFact(
            id: id ?? "\(app)-\(title)", application: app, title: title, workspace: workspace,
            mode: mode, floatReason: reason, isMinimized: minimized, workspaceIsShown: shown
        )
    }

    func testStateResolution() {
        XCTAssertEqual(windowRows([fact("A")]).first?.state, .tiled)
        XCTAssertEqual(
            windowRows([fact("A", mode: .floating, reason: .dialog)]).first?.state,
            .floating(.dialog)
        )
        XCTAssertEqual(windowRows([fact("A", mode: .fullscreen)]).first?.state, .fullscreen)
        XCTAssertEqual(windowRows([fact("A", shown: false)]).first?.state, .hidden)
    }

    func testMinimizedBeatsHiddenAndFloating() {
        let row = windowRows([fact("A", mode: .floating, reason: .manual, minimized: true, shown: false)])
        XCTAssertEqual(row.first?.state, .minimized)
    }

    func testHiddenBeatsFloatingAndTiled() {
        let rows = windowRows([
            fact("A", mode: .floating, reason: .rule, shown: false),
            fact("B", shown: false),
        ])
        XCTAssertEqual(rows.map(\.state), [.hidden, .hidden])
    }

    func testStateLabels() {
        XCTAssertEqual(WindowState.tiled.label, "Tiled")
        XCTAssertEqual(WindowState.floating(.dialog).label, "Floating (dialog)")
        XCTAssertEqual(WindowState.floating(.floatingSubrole).label, "Floating (floating panel)")
        XCTAssertEqual(WindowState.floating(.notResizable).label, "Floating (not resizable)")
        XCTAssertEqual(WindowState.floating(.rule).label, "Floating (window rule)")
        XCTAssertEqual(WindowState.floating(.manual).label, "Floating (toggled)")
        XCTAssertEqual(WindowState.floating(nil).label, "Floating")
        XCTAssertEqual(WindowState.fullscreen.label, "Fullscreen")
        XCTAssertEqual(WindowState.minimized.label, "Minimized")
        XCTAssertEqual(WindowState.hidden.label, "Hidden (other workspace)")
    }

    func testRowsSortByWorkspaceThenAppThenTitleWithUnknownWorkspaceLast() {
        let rows = windowRows([
            fact("Zed", workspace: 1),
            fact("safari", workspace: 2),
            fact("Alacritty", workspace: 2),
            fact("Mail", workspace: nil),
            fact("Code", title: "b", workspace: 1),
            fact("Code", title: "a", workspace: 1),
        ])
        XCTAssertEqual(
            rows.map { "\($0.workspace.map(String.init) ?? "-"):\($0.application):\($0.title)" },
            ["1:Code:a", "1:Code:b", "1:Zed:doc", "2:Alacritty:doc", "2:safari:doc", "-:Mail:doc"]
        )
    }

    func testEmptyTitleShowsPlaceholderAndRowIdIsWindowId() {
        let row = windowRows([fact("A", title: "", id: "9:1")]).first
        XCTAssertEqual(row?.title, "(untitled)")
        XCTAssertEqual(row?.id, "9:1")
    }

    func testSummaryCountsEachStateOnce() {
        let rows = windowRows([
            fact("A"), fact("B"), fact("C", mode: .floating, reason: .dialog),
            fact("D", minimized: true), fact("E", shown: false), fact("F", mode: .fullscreen),
        ])
        XCTAssertEqual(
            windowSummary(rows), "6 windows: 2 tiled, 1 floating, 1 fullscreen, 1 minimized, 1 hidden"
        )
        XCTAssertEqual(windowSummary([]), "No windows managed")
        XCTAssertEqual(windowSummary(windowRows([fact("A")])), "1 window: 1 tiled")
    }

    func testOverviewCarriesConfigIssuesAndDisplays() {
        let facts = SessionFacts(
            configPath: "/tmp/config.toml", configExists: true,
            configMessages: ["line 3: bad"], accessibilityGranted: false,
            currentWorkspace: 2,
            displays: [DisplayFact(id: 20, workspace: 3), DisplayFact(id: 10, workspace: 2)],
            windows: [fact("A")]
        )
        let overview = makeOverview(facts)
        XCTAssertEqual(overview.configIssues, ["line 3: bad"])
        XCTAssertEqual(overview.configSummary, "1 issue in /tmp/config.toml")
        XCTAssertFalse(overview.accessibilityGranted)
        XCTAssertEqual(overview.displayLines, ["Display 1: workspace 2", "Display 2: workspace 3"])
        XCTAssertEqual(overview.windows.count, 1)
    }

    func testOverviewListsEachDisplaysWorkspaceStack() {
        let stack = [
            WorkspaceEntry(index: 1, windows: 3, columns: 2, isActive: false),
            WorkspaceEntry(index: 2, windows: 1, columns: 1, isActive: true),
            WorkspaceEntry(index: 3, windows: 0, columns: 0, isActive: false),
        ]
        let overview = makeOverview(SessionFacts(
            configPath: "/c", configExists: true, configMessages: [],
            accessibilityGranted: true, currentWorkspace: 2,
            displays: [DisplayFact(id: 10, workspace: 2, stack: stack)], windows: []
        ))
        XCTAssertEqual(overview.displayLines, [
            "Display 1: workspace 2", "Stack: 1 (3) · ▸2 (1) · 3 (empty)",
        ])
    }

    func testConfigSummaryVariants() {
        func summary(exists: Bool, messages: [String]) -> String {
            makeOverview(SessionFacts(
                configPath: "/c.toml", configExists: exists, configMessages: messages,
                accessibilityGranted: true, currentWorkspace: 1, displays: [], windows: []
            )).configSummary
        }
        XCTAssertEqual(summary(exists: true, messages: []), "Valid: /c.toml")
        XCTAssertEqual(summary(exists: false, messages: []), "No config file, using defaults (/c.toml)")
        XCTAssertEqual(summary(exists: true, messages: ["a", "b"]), "2 issues in /c.toml")
    }

    func testNoDisplaysFallsBackToCurrentWorkspace() {
        let overview = makeOverview(SessionFacts(
            configPath: "/c", configExists: true, configMessages: [],
            accessibilityGranted: true, currentWorkspace: 4, displays: [], windows: []
        ))
        XCTAssertEqual(overview.displayLines, ["Current workspace: 4"])
    }
}
