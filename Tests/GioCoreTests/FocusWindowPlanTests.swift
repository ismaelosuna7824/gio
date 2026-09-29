import XCTest
@testable import GioCore

/// HD-06: focusing a specific managed window (launcher / window id).
final class FocusWindowPlanTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func manager() -> WorkspaceManager {
        var manager = WorkspaceManager()
        let first = Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 0, windows: [id(1)])],
            focusedColumn: 0, focusedWindow: id(1)
        )
        let third = Workspace(
            id: WorkspaceID(3),
            columns: [
                Column(id: ColumnID(1), width: 0, windows: [id(2)]),
                Column(id: ColumnID(2), width: 0, windows: [id(3), id(4)]),
            ],
            focusedColumn: 0, focusedWindow: id(2)
        )
        manager.update(first)
        manager.update(third)
        return manager
    }

    func testWindowOnAnotherWorkspaceSwitchesToItAndFocusesIt() throws {
        let plan = try XCTUnwrap(planFocusWindow(id(4), in: manager()))
        XCTAssertEqual(plan.index, 3)
        XCTAssertTrue(plan.switchesWorkspace)
        XCTAssertEqual(plan.workspace.focusedWindow, id(4))
        XCTAssertEqual(plan.workspace.focusedColumn, 1)
        XCTAssertEqual(plan.workspace.columns[1].focusedWindowIndex, 1)
    }

    func testWindowOnTheCurrentWorkspaceDoesNotSwitch() throws {
        let plan = try XCTUnwrap(planFocusWindow(id(1), in: manager()))
        XCTAssertEqual(plan.index, 1)
        XCTAssertFalse(plan.switchesWorkspace)
    }

    func testUnknownWindowHasNoPlan() {
        XCTAssertNil(planFocusWindow(id(99), in: manager()))
    }

    func testWindowIDParsesItsStatusText() {
        XCTAssertEqual(WindowID(text: "123:45"), WindowID(pid: 123, elementID: 45))
        for bad in ["", "12", "a:b", "1:2:3", "-1:2", "1:-2", " 1:2"] {
            XCTAssertNil(WindowID(text: bad), bad)
        }
    }
}
