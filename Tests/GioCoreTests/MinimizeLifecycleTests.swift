import XCTest
@testable import GioCore

final class MinimizeLifecycleTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func window(_ element: UInt64, minimized: Bool = false) -> ManagedWindow {
        ManagedWindow(
            id: id(element), pid: 10, application: "App", title: "t\(element)",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), mode: .tiled,
            isMinimized: minimized
        )
    }

    /// Three single-window columns [1][2][3] on workspace 1, focus on `focus`.
    private func fixture(focus: UInt64 = 1) throws -> (WindowRegistry, WorkspaceManager) {
        let registry = WindowRegistry()
        var manager = WorkspaceManager()
        var workspace = manager.currentWorkspace()
        for element in UInt64(1)...3 {
            try registry.register(window(element))
            workspace.columns.append(Column(id: ColumnID(element), width: 0, windows: [id(element)]))
        }
        workspace.focusedColumn = Int(focus) - 1
        workspace.focusedWindow = id(focus)
        manager.update(workspace)
        return (registry, manager)
    }

    private func tiledIDs(_ registry: WindowRegistry, _ manager: WorkspaceManager) -> [[WindowID]] {
        var cache = TileabilityCache()
        let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in .tileable }.modes
        return tilingWorkspace(from: manager.currentWorkspace(), modes: modes).columns.map(\.windows)
    }

    // MARK: Registry state

    func testWindowsAreNotMinimizedByDefault() {
        XCTAssertFalse(window(1).isMinimized)
    }

    func testSetMinimizedKeepsRegistrationAndMode() throws {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.setMinimized(true, for: id(1))
        XCTAssertEqual(registry.find(id(1))?.isMinimized, true)
        XCTAssertEqual(registry.find(id(1))?.mode, .tiled)
        XCTAssertTrue(registry.isManaged(id(1)))
    }

    func testSetMinimizedUnknownThrows() {
        XCTAssertThrowsError(try WindowRegistry().setMinimized(true, for: id(9)))
    }

    // MARK: Layout exclusion

    func testMinimizedWindowLeavesLayoutButNeighboursCloseGap() throws {
        let (registry, manager) = try fixture()
        try registry.setMinimized(true, for: id(2))
        XCTAssertEqual(tiledIDs(registry, manager), [[id(1)], [id(3)]])
    }

    func testMinimizedWindowIsNotProbedForTileability() throws {
        let (registry, _) = try fixture()
        try registry.setMinimized(true, for: id(2))
        var cache = TileabilityCache()
        var probed: [WindowID] = []
        _ = reconcileTileability(registry: registry, cache: &cache, now: 0) { probed.append($0); return .tileable }
        XCTAssertFalse(probed.contains(id(2)))
    }

    // MARK: Minimize / restore

    func testMinimizeMarksWindowAndKeepsItsColumn() throws {
        let (registry, manager0) = try fixture(focus: 1)
        var manager = manager0
        XCTAssertTrue(minimizeWindow(id(2), registry: registry, manager: &manager))
        XCTAssertEqual(registry.find(id(2))?.isMinimized, true)
        XCTAssertEqual(manager.currentWorkspace().columns.map(\.windows), [[id(1)], [id(2)], [id(3)]])
    }

    func testMinimizingFocusedWindowMovesFocusToRightNeighbour() throws {
        let (registry, manager0) = try fixture(focus: 2)
        var manager = manager0
        _ = minimizeWindow(id(2), registry: registry, manager: &manager)
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.focusedWindow, id(3))
        XCTAssertEqual(workspace.focusedColumn, 2)
    }

    func testMinimizingLastFocusedFallsBackToLeftNeighbour() throws {
        let (registry, manager0) = try fixture(focus: 3)
        var manager = manager0
        _ = minimizeWindow(id(3), registry: registry, manager: &manager)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(2))
    }

    func testFocusSkipsOtherMinimizedWindows() throws {
        let (registry, manager0) = try fixture(focus: 2)
        var manager = manager0
        try registry.setMinimized(true, for: id(3))
        _ = minimizeWindow(id(2), registry: registry, manager: &manager)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
    }

    func testMinimizeUnknownWindowReturnsFalse() throws {
        var (registry, manager) = try fixture()
        XCTAssertFalse(minimizeWindow(id(9), registry: registry, manager: &manager))
    }

    func testRestoreReinsertsAtPreviousColumnAndFocuses() throws {
        var (registry, manager) = try fixture(focus: 1)
        _ = minimizeWindow(id(2), registry: registry, manager: &manager)
        XCTAssertTrue(restoreWindow(id(2), registry: registry, manager: &manager))
        XCTAssertEqual(registry.find(id(2))?.isMinimized, false)
        XCTAssertEqual(tiledIDs(registry, manager), [[id(1)], [id(2)], [id(3)]])
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.focusedWindow, id(2))
        XCTAssertEqual(workspace.focusedColumn, 1)
    }

    func testRestoreWithMissingColumnInsertsNextToFocusedColumn() throws {
        var (registry, manager) = try fixture(focus: 1)
        var workspace = manager.currentWorkspace()
        workspace.stripWindows([id(2)])
        manager.update(workspace)
        try registry.setMinimized(true, for: id(2))
        XCTAssertTrue(restoreWindow(id(2), registry: registry, manager: &manager))
        let after = manager.currentWorkspace()
        XCTAssertEqual(after.columns.map(\.windows), [[id(1)], [id(2)], [id(3)]])
        XCTAssertEqual(after.focusedWindow, id(2))
        XCTAssertEqual(after.focusedColumn, 1)
    }

    func testRestoreUnknownWindowReturnsFalse() throws {
        var (registry, manager) = try fixture()
        XCTAssertFalse(restoreWindow(id(9), registry: registry, manager: &manager))
    }

    // MARK: Exposure

    func testListWindowsMarksMinimized() throws {
        var session = CommandSession()
        try session.registry.register(window(1))
        try session.registry.register(window(2, minimized: true))
        let lines = dispatch(.listWindows, session: &session).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("minimized=true") }.count, 1)
        XCTAssertTrue(lines.first { $0.contains("title=t2") }!.contains("minimized=true"))
    }

    func testStatusListsMinimizedWindows() throws {
        var session = CommandSession()
        try session.registry.register(window(1))
        try session.registry.register(window(2, minimized: true))
        let json = try JSONSerialization.jsonObject(
            with: queryStatus(session: session).data(using: .utf8)!
        ) as! [String: Any]
        let minimized = json["minimizedWindows"] as! [[String: String]]
        XCTAssertEqual(minimized.map { $0["id"] }, ["10:2"])
    }
}
