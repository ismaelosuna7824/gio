import CoreGraphics
import XCTest
@testable import GioCore

/// SB-01: the workspace snapshot a custom bar (SketchyBar) reads: the
/// `gio list-workspaces --json` encoder, the hook environment and the diff
/// that decides which hook fires.
final class WorkspaceBarStateTests: XCTestCase {
    private let left = DisplayID(10)
    private let right = DisplayID(20)

    private func window(_ element: UInt64, app: String, pid: pid_t = 1, title: String = "secret title") -> ManagedWindow {
        ManagedWindow(
            id: WindowID(pid: pid, elementID: element), pid: pid, application: app, title: title,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .tiled
        )
    }

    private func put(_ windows: [[ManagedWindow]], on manager: inout WorkspaceManager, registry: WindowRegistry) throws {
        var workspace = manager.currentWorkspace()
        workspace.columns = try windows.enumerated().map { offset, column in
            for window in column {
                try registry.register(window)
            }
            return Column(id: ColumnID(UInt64(offset + 1)), width: 300, windows: column.map(\.id))
        }
        workspace.focusedWindow = windows.first?.first?.id
        manager.update(workspace)
    }

    func testSingleDisplayStateListsEveryWorkspaceWithItsApps() throws {
        var manager = WorkspaceManager()
        manager.syncDisplays([left])
        let registry = WindowRegistry()
        try put([[window(1, app: "Safari"), window(2, app: "Mail")], [window(3, app: "Safari")]], on: &manager, registry: registry)
        XCTAssertTrue(manager.switchTo(2))
        let state = workspaceBarState(manager: manager, registry: registry)
        XCTAssertEqual(state.focusedDisplay, 1)
        XCTAssertEqual(state.focusedWorkspace, 2)
        XCTAssertNil(state.focusedName)
        XCTAssertEqual(state.workspaces, [
            WorkspaceBarEntry(display: 1, index: 1, windows: 3, apps: ["Safari", "Mail"], focused: false, visible: false),
            WorkspaceBarEntry(display: 1, index: 2, windows: 0, apps: [], focused: true, visible: true),
        ])
    }

    func testNamedWorkspacesCarryNameIconAndColor() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left])
        manager.applyNamedWorkspaces([WorkspaceDefinition(name: "Code", icon: "hammer", color: "#ff8800")])
        let state = workspaceBarState(manager: manager, registry: WindowRegistry())
        XCTAssertEqual(state.focusedName, "Code")
        XCTAssertEqual(state.workspaces.first, WorkspaceBarEntry(
            display: 1, index: 1, name: "Code", icon: "hammer", color: "#ff8800",
            windows: 0, apps: [], focused: true, visible: true
        ))
    }

    func testDisplaysAreNumberedLikeWorkspaceDisplayMainFirst() {
        var manager = WorkspaceManager()
        // Position order puts `left` first; `right` is the main display.
        manager.syncDisplays([left, right], main: right)
        XCTAssertEqual(manager.displayNumber(of: right), 1)
        XCTAssertEqual(manager.displayNumber(of: left), 2)
        XCTAssertNil(manager.displayNumber(of: DisplayID(99)))
        let state = workspaceBarState(manager: manager, registry: WindowRegistry())
        XCTAssertEqual(state.workspaces.map(\.display), [1, 2], "main display's stack first")
        XCTAssertEqual(state.workspaces.map(\.visible), [true, true])
        XCTAssertEqual(state.workspaces.filter(\.focused).count, 1)
    }

    func testJSONHasStableKeysNullNamesAndNoTitles() throws {
        var manager = WorkspaceManager()
        manager.syncDisplays([left])
        manager.applyNamedWorkspaces([WorkspaceDefinition(name: "Web")])
        let registry = WindowRegistry()
        try put([[window(1, app: "Safari", title: "Bank statement")]], on: &manager, registry: registry)
        let json = encodeWorkspaceBarJSON(workspaceBarState(manager: manager, registry: registry))
        XCTAssertEqual(
            json,
            #"[{"apps":["Safari"],"color":null,"display":1,"focused":true,"icon":null,"index":1,"name":"Web","visible":true,"windows":1},"#
                + #"{"apps":[],"color":null,"display":1,"focused":false,"icon":null,"index":2,"name":null,"visible":false,"windows":0}]"#
        )
        XCTAssertFalse(json.contains("Bank"))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 2)
    }

    func testListWorkspacesJSONVerb() throws {
        XCTAssertEqual(try parseCLICommand(["list-workspaces", "--json"]).get(), .listWorkspacesJSON)
        XCTAssertEqual(
            parseCLICommand(["list-workspaces", "--yaml"]).mapError { $0 }.failure,
            .missingArgument(name: "--json", command: "list-workspaces")
        )
        var session = CommandSession()
        let output = dispatch(.listWorkspacesJSON, session: &session)
        XCTAssertTrue(output.hasPrefix(#"[{"apps":[]"#), output)
        XCTAssertTrue(cliUsage().contains("gio list-workspaces [--json]"))
        XCTAssertFalse(CLICommand.listWorkspacesJSON.carriesFocusIntent)
    }

    func testFirstSnapshotFiresBothHooks() {
        let state = WorkspaceBarState(focusedDisplay: 1, focusedWorkspace: 1, focusedName: nil, workspaces: [])
        XCTAssertEqual(diffWorkspaceBar(previous: nil, current: state), WorkspaceBarChange(workspace: true, windows: true))
        XCTAssertEqual(diffWorkspaceBar(previous: state, current: state), WorkspaceBarChange(workspace: false, windows: false))
    }

    func testSwitchingWorkspaceIsAWorkspaceChangeOnly() throws {
        var manager = WorkspaceManager()
        manager.syncDisplays([left])
        let registry = WindowRegistry()
        try put([[window(1, app: "Safari")]], on: &manager, registry: registry)
        let before = workspaceBarState(manager: manager, registry: registry)
        XCTAssertTrue(manager.switchTo(2))
        let after = workspaceBarState(manager: manager, registry: registry)
        XCTAssertEqual(diffWorkspaceBar(previous: before, current: after), WorkspaceBarChange(workspace: true, windows: false))
    }

    func testFocusingAnotherDisplayIsAWorkspaceChange() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right], main: left)
        let before = workspaceBarState(manager: manager, registry: WindowRegistry())
        XCTAssertTrue(manager.focusDisplay(right))
        let after = workspaceBarState(manager: manager, registry: WindowRegistry())
        XCTAssertEqual(after.focusedDisplay, 2)
        XCTAssertEqual(diffWorkspaceBar(previous: before, current: after), WorkspaceBarChange(workspace: true, windows: false))
    }

    func testWindowCountsAndAppsAreAWindowsChange() throws {
        var manager = WorkspaceManager()
        manager.syncDisplays([left])
        let registry = WindowRegistry()
        try put([[window(1, app: "Safari")]], on: &manager, registry: registry)
        let before = workspaceBarState(manager: manager, registry: registry)
        var workspace = manager.currentWorkspace()
        try registry.register(window(2, app: "Mail"))
        workspace.columns.append(Column(id: ColumnID(9), width: 300, windows: [WindowID(pid: 1, elementID: 2)]))
        manager.update(workspace)
        let after = workspaceBarState(manager: manager, registry: registry)
        XCTAssertEqual(diffWorkspaceBar(previous: before, current: after), WorkspaceBarChange(workspace: false, windows: true))
        // Focus moving inside the workspace and window titles change nothing.
        workspace = manager.currentWorkspace()
        workspace.focusedWindow = WindowID(pid: 1, elementID: 2)
        manager.update(workspace)
        var retitled = registry.find(WindowID(pid: 1, elementID: 2))!
        retitled.title = "other"
        try registry.update(retitled)
        XCTAssertEqual(
            diffWorkspaceBar(previous: after, current: workspaceBarState(manager: manager, registry: registry)),
            WorkspaceBarChange(workspace: false, windows: false)
        )
    }

    func testHookEnvironment() {
        let state = WorkspaceBarState(focusedDisplay: 2, focusedWorkspace: 3, focusedName: "Mail", workspaces: [])
        let environment = hookEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"], state: state, previousWorkspace: 1, home: "/Users/me"
        )
        XCTAssertEqual(environment["GIO_FOCUSED_WORKSPACE"], "3")
        XCTAssertEqual(environment["GIO_FOCUSED_WORKSPACE_NAME"], "Mail")
        XCTAssertEqual(environment["GIO_PREV_WORKSPACE"], "1")
        XCTAssertEqual(environment["GIO_DISPLAY"], "2")
        XCTAssertEqual(environment["HOME"], "/Users/me")
        // An app opened from Finder gets a bare PATH: Homebrew and ~/.local/bin
        // (the gio link) are added so `sketchybar` and `gio` resolve.
        XCTAssertEqual(
            environment["PATH"], "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        )
        let dynamic = WorkspaceBarState(focusedDisplay: 1, focusedWorkspace: 1, focusedName: nil, workspaces: [])
        let first = hookEnvironment(base: [:], state: dynamic, previousWorkspace: nil, home: "/Users/me")
        XCTAssertEqual(first["GIO_FOCUSED_WORKSPACE_NAME"], "")
        XCTAssertEqual(first["GIO_PREV_WORKSPACE"], "")
        XCTAssertEqual(first["PATH"], "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        let already = hookEnvironment(
            base: ["PATH": "/opt/homebrew/bin:/Users/me/.local/bin:/usr/bin"], state: dynamic, previousWorkspace: nil,
            home: "/Users/me"
        )
        XCTAssertEqual(already["PATH"], "/usr/local/bin:/opt/homebrew/bin:/Users/me/.local/bin:/usr/bin")
    }

    func testHookFlightRunsOneAtATimeAndCoalesces() {
        var flight = HookFlight()
        XCTAssertTrue(flight.request(), "idle: start now")
        XCTAssertFalse(flight.request(), "running: queued")
        XCTAssertFalse(flight.request(), "a second change folds into the same rerun")
        XCTAssertTrue(flight.finish(), "one rerun with the latest state")
        XCTAssertFalse(flight.finish(), "nothing more queued")
        XCTAssertTrue(flight.request())
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
