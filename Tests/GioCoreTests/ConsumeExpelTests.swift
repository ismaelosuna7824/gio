import XCTest
@testable import GioCore

/// NC-05: consume-or-expel-window-left/right (Niri).
final class ConsumeExpelTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func column(_ number: UInt64, _ windows: [UInt64], focus: Int = 0, spec: ColumnWidthSpec? = nil) -> Column {
        Column(
            id: ColumnID(number), width: 0, windows: windows.map(id),
            focusedWindowIndex: focus, widthSpec: spec
        )
    }

    private func workspace(_ columns: [Column], focusedColumn: Int, focused: UInt64) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: columns, focusedColumn: focusedColumn, focusedWindow: id(focused))
    }

    private func layout(_ workspace: Workspace) -> [[UInt64]] {
        workspace.columns.map { $0.windows.map(\.elementID) }
    }

    func testExpelLeftFromStackedColumn() {
        let start = workspace([column(1, [1]), column(2, [2, 3], focus: 0)], focusedColumn: 1, focused: 2)
        let next = consumeOrExpelWindow(in: start, direction: .left)
        XCTAssertEqual(layout(next), [[1], [2], [3]])
        XCTAssertEqual(next.focusedColumn, 1)
        XCTAssertEqual(next.focusedWindow, id(2))
        XCTAssertEqual(next.columns[1].focusedWindowID, id(2))
        XCTAssertEqual(next.columns[2].focusedWindowID, id(3))
        XCTAssertEqual(Set(next.columns.map(\.id.rawValue)).count, 3, "column ids stay unique")
    }

    func testExpelRightFromStackedColumn() {
        let start = workspace([column(1, [1, 2, 3], focus: 1), column(2, [4])], focusedColumn: 0, focused: 2)
        let next = consumeOrExpelWindow(in: start, direction: .right)
        XCTAssertEqual(layout(next), [[1, 3], [2], [4]])
        XCTAssertEqual(next.focusedColumn, 1)
        XCTAssertEqual(next.focusedWindow, id(2))
        XCTAssertEqual(next.columns[0].focusedWindowIndex, 1, "source focus stays in range")
    }

    func testExpelLeftFromFirstColumnCreatesNewFirstColumn() {
        let start = workspace([column(1, [1, 2])], focusedColumn: 0, focused: 2)
        // Focus is the second window of the only column.
        var stacked = start
        stacked.columns[0].focusedWindowIndex = 1
        let next = consumeOrExpelWindow(in: stacked, direction: .left)
        XCTAssertEqual(layout(next), [[2], [1]])
        XCTAssertEqual(next.focusedColumn, 0)
    }

    func testConsumeRightAppendsToNeighborBottomAndRemovesEmptyColumn() {
        let start = workspace([column(1, [1]), column(2, [2, 3])], focusedColumn: 0, focused: 1)
        let next = consumeOrExpelWindow(in: start, direction: .right)
        XCTAssertEqual(layout(next), [[2, 3, 1]])
        XCTAssertEqual(next.focusedColumn, 0)
        XCTAssertEqual(next.focusedWindow, id(1))
        XCTAssertEqual(next.columns[0].focusedWindowIndex, 2)
    }

    func testConsumeLeftAppendsToLeftNeighbor() {
        let start = workspace(
            [column(1, [1]), column(2, [2]), column(3, [3])], focusedColumn: 2, focused: 3
        )
        let next = consumeOrExpelWindow(in: start, direction: .left)
        XCTAssertEqual(layout(next), [[1], [2, 3]])
        XCTAssertEqual(next.focusedColumn, 1)
        XCTAssertEqual(next.focusedWindow, id(3))
    }

    func testNoNeighborIsNoOp() {
        let single = workspace([column(1, [1])], focusedColumn: 0, focused: 1)
        XCTAssertEqual(consumeOrExpelWindow(in: single, direction: .left), single)
        XCTAssertEqual(consumeOrExpelWindow(in: single, direction: .right), single)
        let edge = workspace([column(1, [1]), column(2, [2])], focusedColumn: 0, focused: 1)
        XCTAssertEqual(consumeOrExpelWindow(in: edge, direction: .left), edge)
        let last = workspace([column(1, [1]), column(2, [2])], focusedColumn: 1, focused: 2)
        XCTAssertEqual(consumeOrExpelWindow(in: last, direction: .right), last)
        XCTAssertEqual(consumeOrExpelWindow(in: edge, direction: .up), edge)
        let empty = Workspace(id: WorkspaceID(1))
        XCTAssertEqual(consumeOrExpelWindow(in: empty, direction: .left), empty)
    }

    func testWeightsTravelOnConsumeAndResetOnExpel() {
        var start = workspace([column(1, [1]), column(2, [2, 3])], focusedColumn: 0, focused: 1)
        start.columns[0].heightWeights[id(1)] = 2
        let consumed = consumeOrExpelWindow(in: start, direction: .right)
        XCTAssertEqual(consumed.columns[0].heightWeights[id(1)], 2)

        var stacked = workspace([column(1, [1, 2])], focusedColumn: 0, focused: 1)
        stacked.columns[0].heightWeights = [id(1): 3, id(2): 0.5]
        let expelled = consumeOrExpelWindow(in: stacked, direction: .right)
        XCTAssertEqual(layout(expelled), [[2], [1]])
        XCTAssertEqual(expelled.columns[0].heightWeights, [id(2): 0.5])
        XCTAssertEqual(expelled.columns[1].heightWeights, [:], "a lone window needs no weight")
    }

    func testWidthsStayWithTheirColumns() {
        let start = workspace(
            [column(1, [1], spec: .proportion(0.3)), column(2, [2, 3], spec: .proportion(0.7))],
            focusedColumn: 1, focused: 2
        )
        let expelled = consumeOrExpelWindow(in: start, direction: .left)
        XCTAssertEqual(expelled.columns[0].widthSpec, .proportion(0.3))
        XCTAssertEqual(expelled.columns[1].widthSpec, .standard, "new column takes the default width")
        XCTAssertEqual(expelled.columns[2].widthSpec, .proportion(0.7))
        let consumed = consumeOrExpelWindow(
            in: workspace([column(1, [1], spec: .proportion(0.3)), column(2, [2], spec: .proportion(0.7))],
                          focusedColumn: 0, focused: 1),
            direction: .right
        )
        XCTAssertEqual(consumed.columns[0].widthSpec, .proportion(0.7))
    }

    func testActionNamesAndDefaultBindings() {
        XCTAssertEqual(parseActionName("consume-or-expel-window-left"), .consumeOrExpelLeft)
        XCTAssertEqual(parseActionName("consume-or-expel-window-right"), .consumeOrExpelRight)
        XCTAssertTrue(validActionNames().contains("consume-or-expel-window-left"))
        XCTAssertTrue(validActionNames().contains("consume-or-expel-window-right"))
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "BracketLeft")), .consumeOrExpelLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt], key: "BracketRight")), .consumeOrExpelRight
        )
    }
}
