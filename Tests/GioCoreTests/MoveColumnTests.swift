import XCTest
@testable import GioCore

/// FI-06: move-column-left/right swaps the focused column with its neighbour
/// (Niri semantics). Composition, widths and heights never change and the
/// same window keeps focus; the strip edge is a NO-OP.
final class MoveColumnTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func workspace(focusedColumn: Int = 1) -> Workspace {
        var stacked = Column(id: ColumnID(2), width: 400, windows: [id(2), id(3)])
        stacked.heightWeights = [id(2): 2, id(3): 1]
        stacked.focusedWindowIndex = 1
        var wide = Column(id: ColumnID(3), width: 0, windows: [id(4)])
        wide.widthSpec = .proportion(0.66667)
        return Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 300, windows: [id(1)]), stacked, wide],
            focusedColumn: focusedColumn,
            focusedWindow: focusedColumn == 1 ? id(3) : id(1)
        )
    }

    func testMoveRightSwapsWithTheRightNeighbour() {
        let start = workspace()
        let moved = moveColumn(in: start, direction: .right)
        XCTAssertEqual(moved.columns.map(\.id), [ColumnID(1), ColumnID(3), ColumnID(2)])
        XCTAssertEqual(moved.focusedColumn, 2)
        XCTAssertEqual(moved.focusedWindow, id(3))
    }

    func testMoveLeftSwapsWithTheLeftNeighbour() {
        let moved = moveColumn(in: workspace(), direction: .left)
        XCTAssertEqual(moved.columns.map(\.id), [ColumnID(2), ColumnID(1), ColumnID(3)])
        XCTAssertEqual(moved.focusedColumn, 0)
        XCTAssertEqual(moved.focusedWindow, id(3))
    }

    func testStackedColumnKeepsCompositionWidthAndHeights() {
        let start = workspace()
        let moved = moveColumn(in: start, direction: .right)
        XCTAssertEqual(moved.columns[2], start.columns[1])
        XCTAssertEqual(moved.columns[2].windows, [id(2), id(3)])
        XCTAssertEqual(moved.columns[2].heightWeights[id(2)], 2)
        XCTAssertEqual(moved.columns[2].focusedWindowIndex, 1)
        XCTAssertEqual(moved.columns[1], start.columns[2])
    }

    func testMovingTwiceRoundTrips() {
        let start = workspace()
        let there = moveColumn(in: start, direction: .right)
        XCTAssertEqual(moveColumn(in: there, direction: .left), start)
    }

    func testStripEdgesAreNoOps() {
        let first = workspace(focusedColumn: 0)
        XCTAssertEqual(moveColumn(in: first, direction: .left), first)
        var last = workspace()
        last.focusedColumn = 2
        last.focusedWindow = id(4)
        XCTAssertEqual(moveColumn(in: last, direction: .right), last)
    }

    func testVerticalDirectionsAndInvalidFocusAreNoOps() {
        let start = workspace()
        XCTAssertEqual(moveColumn(in: start, direction: .up), start)
        XCTAssertEqual(moveColumn(in: start, direction: .down), start)
        var broken = start
        broken.focusedColumn = 9
        XCTAssertEqual(moveColumn(in: broken, direction: .right), broken)
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(moveColumn(in: empty, direction: .left), empty)
    }
}
