import XCTest
@testable import GioCore

/// Plan §11: H/L across columns, J/K inside the column, NO-OP on missing
/// targets, per-column focus memory.
final class FocusNavigationTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func workspace() -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)]),
                Column(id: ColumnID(2), width: 300, windows: [id(3)]),
                Column(id: ColumnID(3), width: 300, windows: []),
            ],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
    }

    func testMoveRightAndLeftSyncWindow() {
        let start = workspace()
        let right = moveFocus(in: start, direction: .right)
        XCTAssertEqual(right.focusedColumn, 1)
        XCTAssertEqual(right.focusedWindow, id(3))
        let back = moveFocus(in: right, direction: .left)
        XCTAssertEqual(back.focusedColumn, 0)
        XCTAssertEqual(back.focusedWindow, id(1))
    }

    func testHorizontalBoundariesAreNoOp() {
        let start = workspace()
        XCTAssertEqual(moveFocus(in: start, direction: .left), start)
        let far = moveFocus(in: moveFocus(in: start, direction: .right), direction: .right)
        XCTAssertEqual(far.focusedColumn, 2)
        XCTAssertEqual(moveFocus(in: far, direction: .right), far)
    }

    func testMoveDownAndUpInsideColumn() {
        let start = workspace()
        let down = moveFocus(in: start, direction: .down)
        XCTAssertEqual(down.focusedColumn, 0)
        XCTAssertEqual(down.focusedWindow, id(2))
        XCTAssertEqual(down.columns[0].focusedWindowIndex, 1)
        XCTAssertEqual(moveFocus(in: down, direction: .up).focusedWindow, id(1))
    }

    func testVerticalBoundariesAreNoOp() {
        let start = workspace()
        XCTAssertEqual(moveFocus(in: start, direction: .up), start)
        let single = moveFocus(in: start, direction: .right)
        XCTAssertEqual(moveFocus(in: single, direction: .down), single)
    }

    func testColumnsRememberTheirFocus() {
        var start = workspace()
        start = moveFocus(in: start, direction: .down)
        let away = moveFocus(in: start, direction: .right)
        XCTAssertEqual(away.focusedWindow, id(3))
        let back = moveFocus(in: away, direction: .left)
        XCTAssertEqual(back.focusedWindow, id(2))
    }

    func testLandingOnEmptyColumnClearsWindow() {
        let start = moveFocus(in: workspace(), direction: .right)
        let empty = moveFocus(in: start, direction: .right)
        XCTAssertEqual(empty.focusedColumn, 2)
        XCTAssertNil(empty.focusedWindow)
    }

    func testEmptyOrInvalidWorkspaceIsNoOp() {
        let empty = Workspace(id: WorkspaceID(9))
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveFocus(in: empty, direction: direction), empty)
        }
        var invalid = workspace()
        invalid.focusedColumn = 42
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveFocus(in: invalid, direction: direction), invalid)
        }
    }
}
