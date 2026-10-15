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
        let right = moveFocus(in: start, direction: .right, modes: [:])
        XCTAssertEqual(right.focusedColumn, 1)
        XCTAssertEqual(right.focusedWindow, id(3))
        let back = moveFocus(in: right, direction: .left, modes: [:])
        XCTAssertEqual(back.focusedColumn, 0)
        XCTAssertEqual(back.focusedWindow, id(1))
    }

    func testHorizontalBoundariesAreNoOp() {
        let start = workspace()
        XCTAssertEqual(moveFocus(in: start, direction: .left, modes: [:]), start)
        let far = moveFocus(in: moveFocus(in: start, direction: .right, modes: [:]), direction: .right, modes: [:])
        XCTAssertEqual(far.focusedColumn, 2)
        XCTAssertEqual(moveFocus(in: far, direction: .right, modes: [:]), far)
    }

    func testMoveDownAndUpInsideColumn() {
        let start = workspace()
        let down = moveFocus(in: start, direction: .down, modes: [:])
        XCTAssertEqual(down.focusedColumn, 0)
        XCTAssertEqual(down.focusedWindow, id(2))
        XCTAssertEqual(down.columns[0].focusedWindowIndex, 1)
        XCTAssertEqual(moveFocus(in: down, direction: .up, modes: [:]).focusedWindow, id(1))
    }

    func testVerticalBoundariesAreNoOp() {
        let start = workspace()
        XCTAssertEqual(moveFocus(in: start, direction: .up, modes: [:]), start)
        let single = moveFocus(in: start, direction: .right, modes: [:])
        XCTAssertEqual(moveFocus(in: single, direction: .down, modes: [:]), single)
    }

    func testColumnsRememberTheirFocus() {
        var start = workspace()
        start = moveFocus(in: start, direction: .down, modes: [:])
        let away = moveFocus(in: start, direction: .right, modes: [:])
        XCTAssertEqual(away.focusedWindow, id(3))
        let back = moveFocus(in: away, direction: .left, modes: [:])
        XCTAssertEqual(back.focusedWindow, id(2))
    }

    func testLandingOnEmptyColumnClearsWindow() {
        let start = moveFocus(in: workspace(), direction: .right, modes: [:])
        let empty = moveFocus(in: start, direction: .right, modes: [:])
        XCTAssertEqual(empty.focusedColumn, 2)
        XCTAssertNil(empty.focusedWindow)
    }

    func testEmptyOrInvalidWorkspaceIsNoOp() {
        let empty = Workspace(id: WorkspaceID(9))
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveFocus(in: empty, direction: direction, modes: [:]), empty)
        }
        var invalid = workspace()
        invalid.focusedColumn = 42
        for direction: FocusDirection in [.left, .right, .up, .down] {
            XCTAssertEqual(moveFocus(in: invalid, direction: direction, modes: [:]), invalid)
        }
    }

    private var minimized: WindowID { id(5) }

    private func floatStrip(focusedColumn: Int = 0) -> Workspace {
        let columns = (1...6).map { n in
            Column(id: ColumnID(UInt64(n)), width: 300, windows: [id(UInt64(n))])
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focusedColumn,
            focusedWindow: columns[focusedColumn].focusedWindowID
        )
    }

    private var floatModes: [WindowID: WindowMode] {
        [id(1): .tiled, id(2): .floating, id(3): .floating, minimized: .floating, id(6): .floating]
    }

    func testHorizontalMovesSkipFloatingColumns() {
        let right = moveFocus(in: floatStrip(), direction: .right, modes: floatModes)
        XCTAssertEqual(right.focusedColumn, 3)
        XCTAssertEqual(right.focusedWindow, id(4))
        let left = moveFocus(in: right, direction: .left, modes: floatModes)
        XCTAssertEqual(left.focusedColumn, 0)
        XCTAssertEqual(left.focusedWindow, id(1))
    }

    func testOnlyFloatingOrMinimizedColumnsAheadIsNoOp() {
        let lastTiled = floatStrip(focusedColumn: 3)
        XCTAssertEqual(moveFocus(in: lastTiled, direction: .right, modes: floatModes), lastTiled)
        let firstTiled = floatStrip(focusedColumn: 0)
        XCTAssertEqual(moveFocus(in: firstTiled, direction: .left, modes: floatModes), firstTiled)
    }

    func testFromAFloatingColumnTheNearestTiledColumnTakesFocus() {
        let onFloat = floatStrip(focusedColumn: 2)
        let left = moveFocus(in: onFloat, direction: .left, modes: floatModes)
        XCTAssertEqual(left.focusedColumn, 0)
        XCTAssertEqual(left.focusedWindow, id(1))
        let right = moveFocus(in: onFloat, direction: .right, modes: floatModes)
        XCTAssertEqual(right.focusedColumn, 3)
        XCTAssertEqual(right.focusedWindow, id(4))
    }

    func testEmptyColumnsStayNavigableBetweenFloats() {
        var strip = floatStrip()
        strip.columns.append(Column(id: ColumnID(7), width: 300, windows: []))
        let lastTiled = moveFocus(in: strip, direction: .right, modes: floatModes)
        let empty = moveFocus(in: lastTiled, direction: .right, modes: floatModes)
        XCTAssertEqual(empty.focusedColumn, 6)
        XCTAssertNil(empty.focusedWindow)
    }

    func testAnEmptyModeMapCountsEveryWindowAsTiled() {
        let right = moveFocus(in: floatStrip(), direction: .right, modes: [:])
        XCTAssertEqual(right.focusedColumn, 1)
        XCTAssertEqual(right.focusedWindow, id(2))
    }
}
