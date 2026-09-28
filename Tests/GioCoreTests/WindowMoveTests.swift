import XCTest
@testable import GioCore

/// Plan §12: left/right across columns (edge creates), up/down reorder,
/// focus follows, emptied columns removed, invalid states NO-OP.
final class WindowMoveTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace() -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: [
                Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)]),
                Column(id: ColumnID(2), width: 300, windows: [id(3)]),
            ],
            focusedColumn: 0,
            focusedWindow: id(1)
        )
    }

    func testMoveRightJoinsNextColumn() {
        let moved = moveWindow(in: workspace(), direction: .right)
        XCTAssertEqual(moved.columns.count, 2)
        XCTAssertEqual(moved.columns[0].windows, [id(2)])
        XCTAssertEqual(moved.columns[1].windows, [id(3), id(1)])
        XCTAssertEqual(moved.focusedColumn, 1)
        XCTAssertEqual(moved.focusedWindow, id(1))
        XCTAssertEqual(moved.columns[1].focusedWindowIndex, 1)
    }

    func testMoveRightAtEdgeCreatesColumn() {
        let start = moveWindow(in: workspace(), direction: .right)
        let moved = moveWindow(in: start, direction: .right)
        XCTAssertEqual(moved.columns.count, 3)
        XCTAssertEqual(moved.columns[2].windows, [id(1)])
        XCTAssertEqual(moved.focusedColumn, 2)
        XCTAssertEqual(moved.focusedWindow, id(1))
    }

    func testMoveLeftEmptiesSourceAndRemovesIt() {
        var start = workspace()
        start = moveWindow(in: start, direction: .down)
        start.focusedColumn = 1
        start.focusedWindow = id(3)
        let moved = moveWindow(in: start, direction: .left)
        XCTAssertEqual(moved.columns.count, 1)
        XCTAssertEqual(moved.columns[0].windows, [id(2), id(1), id(3)])
        XCTAssertEqual(moved.focusedColumn, 0)
        XCTAssertEqual(moved.focusedWindow, id(3))
    }

    func testMoveLeftAtEdgeCreatesFirstColumn() {
        let moved = moveWindow(in: workspace(), direction: .left)
        XCTAssertEqual(moved.columns.count, 3)
        XCTAssertEqual(moved.columns[0].windows, [id(1)])
        XCTAssertEqual(moved.columns[1].windows, [id(2)])
        XCTAssertEqual(moved.focusedColumn, 0)
        XCTAssertEqual(moved.focusedWindow, id(1))
    }

    func testMoveUpAndDownReorder() {
        let down = moveWindow(in: workspace(), direction: .down)
        XCTAssertEqual(down.columns[0].windows, [id(2), id(1)])
        XCTAssertEqual(down.focusedWindow, id(1))
        let up = moveWindow(in: down, direction: .up)
        XCTAssertEqual(up.columns[0].windows, [id(1), id(2)])
        XCTAssertEqual(up, workspace())
    }

    func testVerticalEdgesAreNoOp() {
        let start = workspace()
        XCTAssertEqual(moveWindow(in: start, direction: .up), start)
        let single = moveWindow(in: start, direction: .right)
        XCTAssertEqual(moveWindow(in: single, direction: .down), single)
    }

    func testWeightTravelsWithWindow() throws {
        var start = workspace()
        start = resizeFocusedWindowHeight(in: start, factor: 2)
        let moved = moveWindow(in: start, direction: .right)
        XCTAssertEqual(moved.columns[1].heightWeights[id(1)], 2)
        XCTAssertNil(moved.columns[0].heightWeights[id(1)])
    }

    func testInvalidStatesAreNoOp() {
        let empty = Workspace(id: WorkspaceID(9))
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveWindow(in: empty, direction: direction), empty)
        }
        var invalid = workspace()
        invalid.focusedColumn = 42
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveWindow(in: invalid, direction: direction), invalid)
        }
    }
}
