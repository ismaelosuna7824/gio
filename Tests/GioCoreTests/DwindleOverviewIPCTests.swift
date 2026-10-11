import XCTest
@testable import GioCore

/// DW-04: the overview strip from dwindle frames, `gio status` /
/// `gio layout info` / `gio list-workspaces` with the layout and a tree
/// summary, and the `gio layout toggle|scrolling|dwindle` verbs.
final class DwindleOverviewIPCTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 5, elementID: element)
    }

    private func dwindleSession(_ count: UInt64 = 3) -> CommandSession {
        var manager = WorkspaceManager()
        XCTAssertTrue(manager.setLayout(.dwindle))
        for n in 1...count {
            var workspace = manager.currentWorkspace()
            workspace.columns.append(Column(id: ColumnID(n), width: 0, windows: [id(n)]))
            workspace.focusedColumn = workspace.columns.count - 1
            workspace.focusedWindow = id(n)
            manager.update(workspace)
        }
        return CommandSession(manager: manager)
    }

    // MARK: - Overview strip

    func testTheStripOfADwindleWorkspaceUsesItsTiles() throws {
        let workspace = dwindleSession().manager.currentWorkspace()
        let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
        let layout = try workspaceLayoutResult(workspace, modes: [:], engine: engine, viewport: viewport)
        XCTAssertEqual(layout.frames[id(2)], CGRect(x: 505, y: 305, width: 485, height: 285))
        XCTAssertEqual(layout.viewportOffset, 0)
        XCTAssertEqual(layout.contentWidth, 1000)
        let strip = makeWorkspaceStrip(
            workspace: workspace, layout: layout, viewport: viewport, displayID: 1, index: 1, application: { _ in "App" }
        )
        XCTAssertEqual(strip.columns.count, 3, "one tile per window")
        // Drawn top-down: window 2 (top right) starts 10 pt below the top,
        // window 3 (bottom right) 305 pt below it.
        XCTAssertEqual(strip.columns[1].x, 505)
        XCTAssertEqual(strip.columns[1].windows[0].top, 10)
        XCTAssertEqual(strip.columns[2].windows[0].top, 305)
        let miniature = workspaceMiniature(strip)
        XCTAssertFalse(miniature.tiles.contains(where: \.isParked), "every dwindle tile is on screen")
        XCTAssertEqual(miniature.tiles.first { $0.id == "5:3" }?.isFocusedWindow, true)
    }

    func testAScrollingWorkspaceStripIsUnchanged() throws {
        var workspace = Workspace(id: WorkspaceID(1), columns: [
            Column(id: ColumnID(1), width: 0, windows: [id(1)]), Column(id: ColumnID(2), width: 0, windows: [id(2)]),
        ], focusedWindow: id(1))
        workspace.focusedColumn = 0
        let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
        XCTAssertEqual(
            try workspaceLayoutResult(workspace, modes: [:], engine: engine, viewport: viewport),
            try engine.calculate(workspace: workspace, viewport: viewport)
        )
    }

    // MARK: - Status, layout info, list-workspaces

    func testStatusCarriesTheLayoutPerWorkspaceAndATreeSummary() throws {
        var session = dwindleSession()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(dispatch(.status, session: &session).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["layout"] as? String, "dwindle")
        let dwindle = try XCTUnwrap(json["dwindle"] as? [String: Any])
        XCTAssertEqual(dwindle["tree"] as? String, "(5:1 ~ (5:2 ~ 5:3))")
        XCTAssertEqual(dwindle["windows"] as? Int, 3)
        XCTAssertTrue(dwindle["preselection"] is NSNull)
        let stacks = try XCTUnwrap(json["stacks"] as? [[String: Any]])
        let entries = try XCTUnwrap(stacks.first?["workspaces"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["layout"] as? String }, ["dwindle", "scrolling"])

        var scrolling = CommandSession()
        let plain = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(dispatch(.status, session: &scrolling).utf8)) as? [String: Any]
        )
        XCTAssertEqual(plain["layout"] as? String, "scrolling")
        XCTAssertTrue(plain["dwindle"] is NSNull)
    }

    func testTheTreeSummaryShowsShapesRatiosAndTheFocus() {
        var state = DwindleState()
        XCTAssertEqual(dwindleTreeSummary(state), "")
        state.root = .split(DwindleSplit(
            orientation: .horizontal, ratio: 1.2, first: .leaf(id(1)),
            second: .split(DwindleSplit(orientation: .vertical, first: .leaf(id(2)), second: .leaf(id(3))))
        ))
        XCTAssertEqual(dwindleTreeSummary(state), "(5:1 |1.2 (5:2 / 5:3))")
    }

    func testLayoutInfoAndListWorkspacesNameTheLayout() {
        var session = dwindleSession()
        let info = dispatch(.layoutInfo, session: &session)
        XCTAssertTrue(info.hasPrefix("layout=dwindle windows=3 focused=5:3"), info)
        XCTAssertTrue(info.contains("tree=(5:1 ~ (5:2 ~ 5:3))"), info)
        XCTAssertTrue(dispatch(.listWorkspaces, session: &session).contains("*1 columns=3 windows=3 layout=dwindle"))
        var scrolling = CommandSession()
        let plain = dispatch(.layoutInfo, session: &scrolling)
        XCTAssertTrue(plain.hasPrefix("layout=scrolling\ncolumns=0"), plain)
    }

    // MARK: - gio layout toggle|scrolling|dwindle

    func testTheLayoutVerbsParseAndSwitchTheCurrentWorkspace() throws {
        XCTAssertEqual(try parseCLICommand(["layout", "toggle"]).get(), .setLayout(nil))
        XCTAssertEqual(try parseCLICommand(["layout", "dwindle"]).get(), .setLayout(.dwindle))
        XCTAssertEqual(try parseCLICommand(["layout", "scrolling"]).get(), .setLayout(.scrolling))
        XCTAssertEqual(try parseCLICommand(["layout", "info"]).get(), .layoutInfo)
        guard case .failure(.missingArgument(let name, "layout")) = parseCLICommand(["layout", "grid"]) else {
            return XCTFail("an unknown layout is refused")
        }
        XCTAssertEqual(name, "info|toggle|scrolling|dwindle")
        XCTAssertTrue(cliUsage().contains("gio layout info|toggle|scrolling|dwindle"))
        XCTAssertFalse(CLICommand.setLayout(nil).carriesFocusIntent)

        var session = CommandSession()
        XCTAssertEqual(dispatch(.setLayout(.dwindle), session: &session), "workspace 1 layout=dwindle")
        XCTAssertEqual(session.manager.currentWorkspace().layout, .dwindle)
        XCTAssertEqual(dispatch(.setLayout(.dwindle), session: &session), "layout unchanged (workspace 1 is already dwindle)")
        XCTAssertEqual(dispatch(.setLayout(nil), session: &session), "workspace 1 layout=scrolling")
        XCTAssertEqual(session.manager.currentWorkspace().layout, .scrolling)
    }
}
