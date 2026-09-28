import XCTest
@testable import GioCore

/// Plan §15: nine persistent workspaces, switching, independent state,
/// cross-workspace moves with focus repair.
final class WorkspaceManagerTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func populated() -> WorkspaceManager {
        var manager = WorkspaceManager()
        var first = manager.workspace(1)!
        first.columns = [
            Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)]),
            Column(id: ColumnID(2), width: 300, windows: [id(3)]),
        ]
        first.focusedColumn = 0
        first.focusedWindow = id(1)
        first.viewportOffset = 120
        manager.update(first)
        return manager
    }

    func testStartsWithNineEmptyWorkspaces() {
        let manager = WorkspaceManager()
        XCTAssertEqual(manager.current, 1)
        for index in 1...9 {
            let workspace = manager.workspace(index)
            XCTAssertNotNil(workspace)
            XCTAssertTrue(workspace!.columns.isEmpty)
            XCTAssertEqual(workspace!.id, WorkspaceID(UInt64(index)))
        }
        XCTAssertNil(manager.workspace(0))
        XCTAssertNil(manager.workspace(10))
    }

    func testSwitchToValidAndInvalid() {
        var manager = WorkspaceManager()
        XCTAssertTrue(manager.switchTo(5))
        XCTAssertEqual(manager.current, 5)
        XCTAssertFalse(manager.switchTo(0))
        XCTAssertFalse(manager.switchTo(10))
        XCTAssertEqual(manager.current, 5)
    }

    func testWorkspacesKeepIndependentState() {
        var manager = populated()
        XCTAssertTrue(manager.switchTo(2))
        XCTAssertTrue(manager.currentWorkspace().columns.isEmpty)
        XCTAssertTrue(manager.switchTo(1))
        let first = manager.currentWorkspace()
        XCTAssertEqual(first.columns.count, 2)
        XCTAssertEqual(first.focusedWindow, id(1))
        XCTAssertEqual(first.viewportOffset, 120)
    }

    func testUpdateIgnoresForeignIDs() {
        var manager = WorkspaceManager()
        let foreign = Workspace(id: WorkspaceID(99), columns: [
            Column(id: ColumnID(1), width: 100, windows: [id(1)])
        ])
        manager.update(foreign)
        XCTAssertNil(manager.workspace(99))
        XCTAssertTrue(manager.workspace(1)!.columns.isEmpty)
    }

    func testMoveWindowAcrossWorkspaces() {
        var manager = populated()
        XCTAssertTrue(manager.moveWindow(id(1), to: 3))
        let source = manager.workspace(1)!
        XCTAssertEqual(source.columns[0].windows, [id(2)])
        XCTAssertEqual(source.focusedWindow, id(2))
        let dest = manager.workspace(3)!
        XCTAssertEqual(dest.columns.count, 1)
        XCTAssertEqual(dest.columns[0].windows, [id(1)])
        XCTAssertEqual(dest.focusedColumn, 0)
        XCTAssertEqual(dest.focusedWindow, id(1))
        XCTAssertEqual(manager.current, 1)
    }

    func testMoveWindowEmptiesSourceColumn() {
        var manager = populated()
        XCTAssertTrue(manager.moveWindow(id(3), to: 2))
        let source = manager.workspace(1)!
        XCTAssertEqual(source.columns.count, 1)
        XCTAssertEqual(source.columns[0].windows, [id(1), id(2)])
    }

    func testMoveWindowCarriesWeight() {
        var manager = populated()
        var first = manager.workspace(1)!
        first.columns[0].heightWeights[id(1)] = 2.5
        manager.update(first)
        XCTAssertTrue(manager.moveWindow(id(1), to: 4))
        XCTAssertEqual(manager.workspace(4)!.columns[0].heightWeights[id(1)], 2.5)
        XCTAssertNil(manager.workspace(1)!.columns[0].heightWeights[id(1)])
    }

    func testMoveWindowRejectsBadMoves() {
        var manager = populated()
        XCTAssertFalse(manager.moveWindow(id(1), to: 1))
        XCTAssertFalse(manager.moveWindow(id(1), to: 0))
        XCTAssertFalse(manager.moveWindow(id(1), to: 10))
        XCTAssertFalse(manager.moveWindow(id(99), to: 2))
        XCTAssertEqual(manager.workspace(1)!.columns.count, 2)
        XCTAssertTrue(manager.workspace(2)!.columns.isEmpty)
    }

    func testMoveLastWindowResetsSourceFocus() {
        var manager = WorkspaceManager()
        var first = manager.workspace(1)!
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [id(7)])]
        first.focusedColumn = 0
        first.focusedWindow = id(7)
        manager.update(first)
        XCTAssertTrue(manager.moveWindow(id(7), to: 9))
        let source = manager.workspace(1)!
        XCTAssertTrue(source.columns.isEmpty)
        XCTAssertEqual(source.focusedColumn, 0)
        XCTAssertNil(source.focusedWindow)
    }
}
