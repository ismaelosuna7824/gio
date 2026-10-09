import XCTest
@testable import GioCore

/// NC-09: niri `focus-column-first/last`, `move-column-to-first/last` and
/// `swap-window-left/right` on workspace state. Edges and invalid focus are
/// NO-OPs (the workspace comes back unchanged).
final class ColumnNavigationTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// `[1] [2 3*] [4]`, the stacked middle column focused on window 3.
    private func workspace(focusedColumn: Int = 1) -> Workspace {
        var stacked = Column(id: ColumnID(2), width: 400, windows: [id(2), id(3)])
        stacked.heightWeights = [id(2): 2, id(3): 1]
        stacked.focusedWindowIndex = 1
        var wide = Column(id: ColumnID(3), width: 0, windows: [id(4)])
        wide.widthSpec = .proportion(0.66667)
        let columns = [Column(id: ColumnID(1), width: 300, windows: [id(1)]), stacked, wide]
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focusedColumn,
            focusedWindow: columns[focusedColumn].focusedWindowID
        )
    }

    // MARK: Focus first / last

    func testFocusFirstAndLastColumnKeepEachColumnsFocusedWindow() {
        let first = focusColumnFirst(in: workspace())
        XCTAssertEqual(first.focusedColumn, 0)
        XCTAssertEqual(first.focusedWindow, id(1))
        XCTAssertEqual(first.columns, workspace().columns, "focus never moves windows")
        let last = focusColumnLast(in: workspace())
        XCTAssertEqual(last.focusedColumn, 2)
        XCTAssertEqual(last.focusedWindow, id(4))
        let back = focusColumnLast(in: focusColumnFirst(in: workspace(focusedColumn: 2)))
        XCTAssertEqual(back.focusedWindow, id(4))
    }

    func testFocusFirstAndLastAtTheEdgeOrEmptyAreNoOps() {
        XCTAssertEqual(focusColumnFirst(in: workspace(focusedColumn: 0)), workspace(focusedColumn: 0))
        XCTAssertEqual(focusColumnLast(in: workspace(focusedColumn: 2)), workspace(focusedColumn: 2))
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(focusColumnFirst(in: empty), empty)
        XCTAssertEqual(focusColumnLast(in: empty), empty)
    }

    // MARK: Move column to first / last

    func testMoveColumnToFirstAndLastKeepTheColumnAndItsFocus() {
        let start = workspace()
        let first = moveColumnToFirst(in: start)
        XCTAssertEqual(first.columns.map(\.id), [ColumnID(2), ColumnID(1), ColumnID(3)])
        XCTAssertEqual(first.focusedColumn, 0)
        XCTAssertEqual(first.focusedWindow, id(3))
        XCTAssertEqual(first.columns[0], start.columns[1], "windows, width and heights travel")
        let last = moveColumnToLast(in: start)
        XCTAssertEqual(last.columns.map(\.id), [ColumnID(1), ColumnID(3), ColumnID(2)])
        XCTAssertEqual(last.focusedColumn, 2)
        XCTAssertEqual(last.focusedWindow, id(3))
        let fromLeft = moveColumnToLast(in: workspace(focusedColumn: 0))
        XCTAssertEqual(fromLeft.columns.map(\.id), [ColumnID(2), ColumnID(3), ColumnID(1)])
    }

    func testMoveColumnToFirstAndLastAtTheEdgeAreNoOps() {
        XCTAssertEqual(moveColumnToFirst(in: workspace(focusedColumn: 0)), workspace(focusedColumn: 0))
        XCTAssertEqual(moveColumnToLast(in: workspace(focusedColumn: 2)), workspace(focusedColumn: 2))
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(moveColumnToFirst(in: empty), empty)
        XCTAssertEqual(moveColumnToLast(in: empty), empty)
    }

    // MARK: Swap window

    /// Niri: the focused window trades places with the neighbouring column's
    /// focused window; both columns keep their width and focused row, focus
    /// follows the window and heights travel with the windows.
    func testSwapWithAStackedNeighbourTradesTheFocusedWindows() {
        var left = Column(id: ColumnID(1), width: 300, windows: [id(1), id(5)])
        left.focusedWindowIndex = 0
        left.heightWeights = [id(1): 3]
        var start = workspace()
        start.columns[0] = left
        // [1 5] [2 3*] [4]: window 3 swaps with window 1 (the left column's focused row).
        let swapped = swapWindow(in: start, direction: .left)
        XCTAssertEqual(swapped.columns.map(\.windows), [[id(3), id(5)], [id(2), id(1)], [id(4)]])
        XCTAssertEqual(swapped.columns.map(\.id), start.columns.map(\.id), "columns stay in place")
        XCTAssertEqual(swapped.columns[0].widthSpec, start.columns[0].widthSpec, "widths stay with the column")
        XCTAssertEqual(swapped.columns[1].widthSpec, start.columns[1].widthSpec)
        XCTAssertEqual(swapped.focusedColumn, 0)
        XCTAssertEqual(swapped.focusedWindow, id(3))
        XCTAssertEqual(swapped.columns[0].focusedWindowIndex, 0)
        XCTAssertEqual(swapped.columns[1].focusedWindowIndex, 1)
        XCTAssertEqual(swapped.columns[0].heightWeights, [id(3): 1])
        XCTAssertEqual(swapped.columns[1].heightWeights, [id(2): 2, id(1): 3])
    }

    func testSwapWithAShorterNeighbourLeavesTheOtherWindowBehind() {
        // [2 3*] [4]: window 3 goes right, window 4 takes its row on the left.
        let swapped = swapWindow(in: workspace(), direction: .right)
        XCTAssertEqual(swapped.columns.map(\.windows), [[id(1)], [id(2), id(4)], [id(3)]])
        XCTAssertEqual(swapped.columns[2].widthSpec, .proportion(0.66667))
        XCTAssertEqual(swapped.focusedColumn, 2)
        XCTAssertEqual(swapped.focusedWindow, id(3))
        XCTAssertEqual(swapped.columns[1].focusedWindowIndex, 1)
        XCTAssertEqual(swapped.columns[1].heightWeights, [id(2): 2])
        XCTAssertEqual(swapped.columns[2].heightWeights, [id(3): 1])
    }

    func testSwapBetweenTwoLoneWindowsMovesTheColumn() {
        let start = workspace(focusedColumn: 0)
        let lone = Workspace(
            id: WorkspaceID(1),
            columns: [start.columns[0], start.columns[2]],
            focusedColumn: 0, focusedWindow: id(1)
        )
        XCTAssertEqual(swapWindow(in: lone, direction: .right), moveColumn(in: lone, direction: .right))
    }

    func testSwapAtTheEdgeVerticallyOrWithoutFocusIsANoOp() {
        XCTAssertEqual(swapWindow(in: workspace(focusedColumn: 0), direction: .left), workspace(focusedColumn: 0))
        XCTAssertEqual(swapWindow(in: workspace(focusedColumn: 2), direction: .right), workspace(focusedColumn: 2))
        XCTAssertEqual(swapWindow(in: workspace(), direction: .up), workspace())
        XCTAssertEqual(swapWindow(in: workspace(), direction: .down), workspace())
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(swapWindow(in: empty, direction: .left), empty)
    }
}
