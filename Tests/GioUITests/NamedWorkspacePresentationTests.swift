import GioCore
import XCTest
@testable import GioUI

/// NW-04: workspace names in the Overview, the menu bar and the launcher.
final class NamedWorkspacePresentationTests: XCTestCase {
    private let code = WorkspaceEntry(
        index: 1, windows: 2, columns: 2, isActive: false, name: "Code",
        icon: "chevron.left.forwardslash.chevron.right", color: "#5e9eff"
    )
    private let browsers = WorkspaceEntry(index: 2, windows: 1, columns: 1, isActive: true, name: "Browsers", icon: "globe")
    private let dynamic = WorkspaceEntry(index: 3, windows: 0, columns: 0, isActive: false)

    // MARK: - Titles

    func testTitlesShowNameForNamedAndIndexForDynamic() {
        XCTAssertEqual(workspaceTitle(code), "1 · Code")
        XCTAssertEqual(workspaceTitle(dynamic), "Workspace 3")
        XCTAssertEqual(workspaceShortName(code), "Code")
        XCTAssertEqual(workspaceShortName(dynamic), "Workspace 3")
    }

    func testStripTitleUsesTheFocusedDisplaysEntry() {
        let strip = WorkspaceStripFact(
            displayID: 7, workspace: 2, viewportWidth: 100, viewportHeight: 100, viewportOffset: 0,
            contentWidth: 100, columns: [], focusedColumn: nil, focusedWindowID: nil
        )
        let facts = SessionFacts(
            configPath: "", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 2,
            displays: [DisplayFact(id: 7, workspace: 2, stack: [code, browsers, dynamic])],
            windows: [], strip: strip
        )
        XCTAssertEqual(stripTitle(facts), "2 · Browsers")
        let unnamed = SessionFacts(
            configPath: "", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 3, displays: [DisplayFact(id: 7, workspace: 3)], windows: []
        )
        XCTAssertEqual(stripTitle(unnamed), "Workspace 3")
    }

    func testWindowGroupTitlesUseNamesOnASingleDisplay() {
        let single = SessionFacts(
            configPath: "", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 2, displays: [DisplayFact(id: 7, workspace: 2, stack: [code, browsers, dynamic])],
            windows: []
        )
        XCTAssertEqual(windowGroupTitle(workspace: 1, facts: single), "1 · Code")
        XCTAssertEqual(windowGroupTitle(workspace: 3, facts: single), "Workspace 3")
        XCTAssertEqual(windowGroupTitle(workspace: nil, facts: single), "Other windows")
        let two = SessionFacts(
            configPath: "", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 2,
            displays: [DisplayFact(id: 7, workspace: 2, stack: [code]), DisplayFact(id: 8, workspace: 1)],
            windows: []
        )
        XCTAssertEqual(windowGroupTitle(workspace: 1, facts: two), "Workspace 1", "indices are per display")
    }

    func testCompactWindowCount() {
        XCTAssertEqual(compactWindowCount(0), "Empty")
        XCTAssertEqual(compactWindowCount(1), "1")
        XCTAssertEqual(compactWindowCount(12), "12")
    }

    // MARK: - Menu bar

    func testStatusParsesNamesIconsAndColors() throws {
        let json = #"""
        {"workspace":2,"columns":1,"windows":3,"stacks":[{"display":7,"focused":true,
        "workspaces":[{"index":1,"windows":2,"columns":2,"active":false,"name":"Code","icon":"chevron.left.forwardslash.chevron.right","color":"#5e9eff"},
        {"index":2,"windows":1,"columns":1,"active":true,"name":"Browsers","icon":"globe"},
        {"index":3,"windows":0,"columns":0,"active":false}]}]}
        """#
        let state = try XCTUnwrap(parseBarStatus(json))
        XCTAssertEqual(state.stacks[0].workspaces, [code, browsers, dynamic])
    }

    func testMenuRowsCarryNamesAndIcons() {
        let state = BarSessionState(
            workspace: 2, windows: 3, columns: 1, focused: nil,
            stacks: [BarStack(display: 7, focused: true, workspaces: [code, browsers, dynamic])]
        )
        let model = barMenuModel(state)
        let rows = model.sections[0].rows
        XCTAssertEqual(rows.map(\.title), ["Code", "Browsers", "Workspace 3"])
        XCTAssertEqual(rows.map(\.symbol), ["chevron.left.forwardslash.chevron.right", "globe", nil])
        XCTAssertEqual(rows.map(\.color), ["#5e9eff", nil, nil])
        XCTAssertEqual(rows.map(\.detail), ["⌥1 · 2 windows", "⌥2 · 1 window", "⌥3 · Empty"])
        XCTAssertEqual(model.subtitle, "Browsers (2 of 3) · 3 windows")
        XCTAssertEqual(barBadgeText(state), "2", "the status item keeps the index")
    }

    func testMenuWithoutNamesIsUnchanged() {
        let plain = [
            WorkspaceEntry(index: 1, windows: 2, columns: 1, isActive: true),
            WorkspaceEntry(index: 2, windows: 0, columns: 0, isActive: false),
        ]
        let model = barMenuModel(BarSessionState(
            workspace: 1, windows: 2, columns: 1, focused: nil,
            stacks: [BarStack(display: 1, focused: true, workspaces: plain)]
        ))
        XCTAssertEqual(model.sections[0].rows.map(\.title), ["Workspace 1", "Workspace 2"])
        XCTAssertEqual(model.subtitle, "Workspace 1 of 2 · 2 windows")
    }

    // MARK: - Launcher

    private func facts(stack: [WorkspaceEntry]) -> SessionFacts {
        SessionFacts(
            configPath: "", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 2, displays: [DisplayFact(id: 7, workspace: 2, stack: stack)], windows: []
        )
    }

    func testLauncherListsNamedWorkspacesOfTheFocusedDisplay() {
        let entries = launcherWorkspaceEntries(from: facts(stack: [code, browsers, dynamic]))
        XCTAssertEqual(entries, [
            .workspace(index: 1, name: "Code", icon: "chevron.left.forwardslash.chevron.right", color: "#5e9eff"),
            .workspace(index: 2, name: "Browsers", icon: "globe", color: nil),
        ])
        XCTAssertEqual(launcherWorkspaceEntries(from: nil), [])
        let entry = entries[0]
        XCTAssertEqual(entry.title, "Go to workspace Code")
        XCTAssertEqual(entry.kindLabel, "Workspace")
        XCTAssertEqual(entry.listID, "workspace:1")
        XCTAssertEqual(launcherIPCArguments(entry), ["workspace", "1"])
        XCTAssertNil(launcherIPCArguments(.shellCommand("ls")))
    }

    func testWorkspaceMatchesByNameAndRanksFirstOnATie() {
        let entries: [LauncherEntry] = [
            .app(name: "Code", bundleID: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app"),
            .window(id: "1:1", application: "Code", windowTitle: "main.swift", workspace: 1),
        ] + launcherWorkspaceEntries(from: facts(stack: [code, browsers]))
        let results = searchLauncherEntries("code", in: entries)
        XCTAssertEqual(results.first, .workspace(index: 1, name: "Code", icon: code.icon, color: code.color))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(searchLauncherEntries("bro", in: entries).map(\.listID), ["workspace:2"])
        XCTAssertEqual(searchLauncherEntries("go to", in: entries), [], "the verb is not a match")
        XCTAssertEqual(
            routeLauncherInput("brow", apps: entries),
            .runEntry(.workspace(index: 2, name: "Browsers", icon: "globe", color: nil))
        )
    }
}
