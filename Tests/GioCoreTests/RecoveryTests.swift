import XCTest
@testable import GioCore

/// Plan §23: stale pruning with focus repair, proof-positive reaping,
/// freeze on untrusted input, display drops without workspace damage.
final class RecoveryTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func window(_ element: UInt64, pid: pid_t = 10) -> ManagedWindow {
        ManagedWindow(
            id: id(element, pid: pid), pid: pid, application: "A", title: "a",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .tiled
        )
    }

    private func state() throws -> RecoveryState {
        let registry = WindowRegistry()
        try registry.register(window(1))
        try registry.register(window(2))
        try registry.register(window(3, pid: 99))
        var manager = WorkspaceManager()
        var first = manager.workspace(1)!
        first.columns = [
            Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)]),
            Column(id: ColumnID(2), width: 300, windows: [id(3, pid: 99)]),
        ]
        first.focusedColumn = 0
        first.focusedWindow = id(1)
        manager.update(first)
        var displays = DisplayManager()
        displays.connect(DisplayID(1), frame: CGRect(x: 0, y: 0, width: 100, height: 100), workspace: WorkspaceID(1))
        displays.connect(DisplayID(2), frame: CGRect(x: 100, y: 0, width: 100, height: 100), workspace: WorkspaceID(2))
        return RecoveryState(registry: registry, manager: manager, displays: displays)
    }

    func testPrunesStaleAndRepairsFocus() throws {
        var world = try state()
        let report = recover(
            state: &world,
            input: RecoveryInput(
                liveIDs: [id(1)],
                displaysSeen: [DisplayID(1), DisplayID(2)]
            )
        )
        XCTAssertEqual(report.prunedStale, [id(2), id(3, pid: 99)])
        XCTAssertFalse(report.permissionLost)
        XCTAssertFalse(report.snapshotIncomplete)
        XCTAssertNil(world.registry.find(id(2)))
        let first = world.manager.workspace(1)!
        XCTAssertEqual(first.columns.count, 1)
        XCTAssertEqual(first.columns[0].windows, [id(1)])
        XCTAssertEqual(first.focusedWindow, id(1))
    }

    func testReapsTerminatedProcessesDespiteFreeze() throws {
        var world = try state()
        let report = recover(
            state: &world,
            input: RecoveryInput(
                liveIDs: [id(1), id(2), id(3, pid: 99)],
                terminatedPIDs: [99],
                permissionGranted: false,
                snapshotComplete: false
            )
        )
        XCTAssertTrue(report.permissionLost)
        XCTAssertEqual(report.reapedProcesses, [99])
        XCTAssertTrue(report.prunedStale.isEmpty)
        XCTAssertNil(world.registry.find(id(3, pid: 99)))
        // Untouched by the freeze: the merely-absent stay.
        XCTAssertNotNil(world.registry.find(id(1)))
        let first = world.manager.workspace(1)!
        XCTAssertEqual(first.columns.count, 1)
    }

    func testFreezeOnLostPermission() throws {
        var world = try state()
        let report = recover(
            state: &world,
            input: RecoveryInput(liveIDs: [], permissionGranted: false, snapshotComplete: true)
        )
        XCTAssertTrue(report.permissionLost)
        XCTAssertEqual(world.registry.registeredCount, 3)
        XCTAssertEqual(world.manager.workspace(1)!.columns.count, 2)
    }

    func testFreezeOnIncompleteSnapshot() throws {
        var world = try state()
        let report = recover(
            state: &world,
            input: RecoveryInput(liveIDs: [], snapshotComplete: false)
        )
        XCTAssertTrue(report.snapshotIncomplete)
        XCTAssertFalse(report.permissionLost)
        XCTAssertEqual(world.registry.registeredCount, 3)
    }

    func testDropsDisplaysWithoutTouchingWorkspaces() throws {
        var world = try state()
        let report = recover(
            state: &world,
            input: RecoveryInput(
                liveIDs: [id(1), id(2), id(3, pid: 99)],
                displaysSeen: [DisplayID(1)]
            )
        )
        XCTAssertEqual(report.droppedDisplays, [DisplayID(2)])
        XCTAssertNil(world.displays.display(DisplayID(2)))
        XCTAssertNotNil(world.displays.display(DisplayID(1)))
        XCTAssertEqual(world.manager.workspace(2)!.id, WorkspaceID(2))
        XCTAssertEqual(world.manager.workspace(1)!.columns.count, 2)
    }

    func testStripRepairsShiftedFocus() {
        var workspace = Workspace(
            id: WorkspaceID(1),
            columns: [Column(
                id: ColumnID(1), width: 300, windows: [id(1), id(2), id(3)],
                focusedWindowIndex: 2
            )],
            focusedColumn: 0,
            focusedWindow: id(3)
        )
        workspace.stripWindows([id(1)])
        // Same window keeps focus at its shifted index.
        XCTAssertEqual(workspace.columns[0].windows, [id(2), id(3)])
        XCTAssertEqual(workspace.columns[0].focusedWindowIndex, 1)
        XCTAssertEqual(workspace.focusedWindow, id(3))
        workspace.stripWindows([id(3)])
        // Removed focus falls back to the neighbor.
        XCTAssertEqual(workspace.columns[0].windows, [id(2)])
        XCTAssertEqual(workspace.focusedWindow, id(2))
    }

    func testStripEmptiesWorkspace() {
        var workspace = Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 300, windows: [id(1)])],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
        workspace.stripWindows([id(1)])
        XCTAssertTrue(workspace.columns.isEmpty)
        XCTAssertNil(workspace.focusedWindow)
        XCTAssertEqual(workspace.focusedColumn, 0)
    }
}
