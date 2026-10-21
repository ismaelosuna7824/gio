import CoreGraphics
import XCTest
@testable import GioCore

/// WO-02: a window tile dragged in the workspace overview reorders its
/// workspace's columns or moves to another workspace of the same display,
/// without following it there and without touching the target's focus.
final class OverviewMoveTests: XCTestCase {
    private let display = WorkspaceManager.placeholderDisplay

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func move(_ element: UInt64, to workspace: Int, column: Int) -> OverviewMove {
        OverviewMove(windowID: "10:\(element)", workspace: workspace, column: column)
    }

    /// Workspace k holds `layout[k]`: columns of window numbers, each column
    /// `.points(100 * its first window)` wide, focused on its first window;
    /// the trailing spare follows. Workspace 1 is the current one.
    private func makeManager(_ layout: [[[UInt64]]]) -> WorkspaceManager {
        var manager = WorkspaceManager()
        for (index, columns) in layout.enumerated() {
            XCTAssertTrue(manager.switchTo(index + 1))
            var workspace = manager.currentWorkspace()
            workspace.columns = columns.enumerated().map { offset, windows in
                Column(
                    id: ColumnID(UInt64(offset + 1)), width: 0, windows: windows.map(id),
                    widthSpec: .points(CGFloat(100 * windows[0]))
                )
            }
            workspace.focusedColumn = 0
            workspace.focusedWindow = columns.first.map { id($0[0]) }
            manager.update(workspace)
        }
        XCTAssertTrue(manager.switchTo(1))
        return manager
    }

    private func space(_ manager: WorkspaceManager, _ index: Int) -> Workspace {
        manager.workspace(index, on: display)!
    }

    /// Focus window `element` of workspace `index` (its column and row).
    private func focus(_ manager: inout WorkspaceManager, _ index: Int, _ element: UInt64) {
        var workspace = space(manager, index)
        let column = workspace.columns.firstIndex { $0.windows.contains(id(element)) }!
        workspace.focusedColumn = column
        workspace.columns[column].focusedWindowIndex = workspace.columns[column].windows.firstIndex(of: id(element))!
        workspace.focusedWindow = id(element)
        manager.update(workspace)
    }

    private func columns(_ manager: WorkspaceManager, _ index: Int) -> [[UInt64]] {
        space(manager, index).columns.map { $0.windows.map(\.elementID) }
    }

    private func focused(_ manager: WorkspaceManager, _ index: Int) -> UInt64? {
        space(manager, index).focusedWindow?.elementID
    }

    /// The focused column holds the focused window (when there is one).
    private func assertFocusConsistent(
        _ manager: WorkspaceManager, _ index: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let workspace = space(manager, index)
        if let window = workspace.focusedWindow {
            XCTAssertEqual(workspace.focusedColumnRef?.windows.contains(window), true, file: file, line: line)
        }
    }

    /// NF-02 invariants: one trailing empty workspace, no empty inactive one.
    private func assertInvariants(_ manager: WorkspaceManager, file: StaticString = #filePath, line: UInt = #line) {
        for display in manager.displayIDs {
            let stack = manager.stack(on: display)
            XCTAssertTrue(stack.last?.columns.isEmpty ?? false, "no trailing spare", file: file, line: line)
            for workspace in stack.dropLast() where workspace.columns.isEmpty {
                XCTAssertEqual(workspace.id, manager.activeID(on: display), "empty inactive kept", file: file, line: line)
            }
        }
    }

    // MARK: - Reorder within a workspace

    func testDroppingALoneWindowLaterInItsWorkspaceMovesItsColumnThere() {
        var manager = makeManager([[[1], [2], [3], [4]]])
        let column = space(manager, 1).columns[0]
        XCTAssertEqual(manager.moveWindowFromOverview(move(1, to: 1, column: 3), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 1), [[2], [3], [1], [4]], "before the shown column 3 (window 4)")
        XCTAssertEqual(space(manager, 1).columns[2], column, "the same column: id and width kept")
        XCTAssertEqual(focused(manager, 1), 1, "the focused window stays focused")
        XCTAssertEqual(space(manager, 1).focusedColumn, 2, "and its column follows it")
    }

    func testDroppingALoneWindowEarlierOrAtTheEndReordersTheColumns() {
        var first = makeManager([[[1], [2], [3], [4]]])
        XCTAssertEqual(first.moveWindowFromOverview(move(4, to: 1, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(first, 1), [[4], [1], [2], [3]])
        XCTAssertEqual(focused(first, 1), 1)
        XCTAssertEqual(space(first, 1).focusedColumn, 1, "the focused column shifted right")

        var last = makeManager([[[1], [2], [3], [4]]])
        XCTAssertEqual(last.moveWindowFromOverview(move(2, to: 1, column: 4), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(last, 1), [[1], [3], [4], [2]], "column count = after the last")
        XCTAssertEqual(space(last, 1).columns.map(\.widthSpec), [.points(100), .points(300), .points(400), .points(200)])
    }

    func testDroppingAWindowAtItsOwnPlaceIsUnchanged() {
        let before = makeManager([[[1], [2], [3]]])
        for column in [1, 2] {
            var manager = before
            XCTAssertEqual(
                manager.moveWindowFromOverview(move(2, to: 1, column: column), on: display, modes: [:]), .unchanged,
                "just before or just after itself"
            )
            XCTAssertEqual(manager, before)
        }
    }

    func testAStackedWindowLeavesItsColumnAsItsOwnColumnWithTheColumnsWidth() {
        var manager = makeManager([[[1, 2, 3], [4]]])
        var workspace = space(manager, 1)
        workspace.columns[0].heightWeights = [id(2): 1.5, id(3): 0.5]
        manager.update(workspace)
        focus(&manager, 1, 2)
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 1, column: 2), on: display, modes: [:]), .moved)
        let after = space(manager, 1)
        XCTAssertEqual(columns(manager, 1), [[1, 3], [4], [2]])
        XCTAssertEqual(after.columns[2].widthSpec, .points(100), "the source column's width")
        XCTAssertEqual(after.columns[0].widthSpec, .points(100), "the source column keeps its width")
        XCTAssertEqual(after.columns[0].heightWeights, [id(3): 0.5], "the rest keep their heights")
        XCTAssertEqual(Set(after.columns.map(\.id)).count, 3, "a fresh column id")
        XCTAssertEqual(focused(manager, 1), 2, "the workspace's focused window does not change")
        assertFocusConsistent(manager, 1)
    }

    func testAStackedWindowDroppedNextToItsOwnColumnIsExpelled() {
        var manager = makeManager([[[1, 2]]])
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 1, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 1), [[2], [1]])
        XCTAssertEqual(focused(manager, 1), 1)
        XCTAssertEqual(space(manager, 1).focusedColumn, 1)
    }

    // MARK: - Across workspaces

    func testALoneColumnMovesToAnotherWorkspaceWithItsWidthsWithoutFollowingIt() {
        var manager = makeManager([[[1], [2]], [[3], [4]]])
        var source = space(manager, 1)
        source.columns[0].widthSpec = .proportion(1)
        source.columns[0].savedWidthSpec = .proportion(0.5)
        manager.update(source)
        focus(&manager, 2, 4)
        let current = manager.currentID
        XCTAssertEqual(manager.moveWindowFromOverview(move(1, to: 2, column: 1), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 1), [[2]])
        XCTAssertEqual(columns(manager, 2), [[3], [1], [4]])
        let landed = space(manager, 2).columns[1]
        XCTAssertEqual(landed.widthSpec, .proportion(1))
        XCTAssertEqual(landed.savedWidthSpec, .proportion(0.5), "a maximized column stays restorable")
        XCTAssertEqual(Set(space(manager, 2).columns.map(\.id)).count, 3, "no column id clash")
        XCTAssertEqual(focused(manager, 2), 4, "the target's focus does not change")
        XCTAssertEqual(space(manager, 2).focusedColumn, 2)
        XCTAssertEqual(manager.currentID, current, "no follow")
        XCTAssertEqual(manager.focusedDisplay, display)
        assertInvariants(manager)
    }

    func testAStackedWindowMovesToAnotherWorkspaceAndItsColumnRepairsItsFocus() {
        var manager = makeManager([[[1, 2, 3], [4]], [[5]]])
        focus(&manager, 1, 2)
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 2, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 1), [[1, 3], [4]])
        XCTAssertEqual(columns(manager, 2), [[2], [5]])
        XCTAssertEqual(space(manager, 2).columns[0].widthSpec, .points(100))
        XCTAssertEqual(focused(manager, 1), 3, "the window below takes the focus, as when a window leaves")
        XCTAssertEqual(space(manager, 1).focusedColumn, 0)
        XCTAssertEqual(focused(manager, 2), 5)
        XCTAssertEqual(space(manager, 2).focusedColumn, 1)
        assertFocusConsistent(manager, 1)
    }

    func testIntoTheEmptySpareTheWindowBecomesItsFocusAndANewSpareAppears() {
        var manager = makeManager([[[1], [2]]])
        XCTAssertEqual(manager.stack(on: display).count, 2)
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 2, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(manager.stack(on: display).count, 3)
        XCTAssertEqual(columns(manager, 2), [[2]])
        XCTAssertEqual(focused(manager, 2), 2)
        XCTAssertEqual(space(manager, 2).focusedColumn, 0)
        XCTAssertTrue(space(manager, 3).columns.isEmpty)
        XCTAssertEqual(manager.current, 1)
        assertInvariants(manager)
    }

    func testTheSourceFocusFallsToTheNeighbourWhenTheFocusedWindowLeaves() {
        var middle = makeManager([[[1], [2], [3]], [[4]]])
        focus(&middle, 1, 2)
        XCTAssertEqual(middle.moveWindowFromOverview(move(2, to: 2, column: 1), on: display, modes: [:]), .moved)
        XCTAssertEqual(focused(middle, 1), 3, "the column on the right takes over")
        XCTAssertEqual(space(middle, 1).focusedColumn, 1)

        var last = makeManager([[[1], [2], [3]], [[4]]])
        focus(&last, 1, 3)
        XCTAssertEqual(last.moveWindowFromOverview(move(3, to: 2, column: 1), on: display, modes: [:]), .moved)
        XCTAssertEqual(focused(last, 1), 2, "else the one on the left")
        XCTAssertEqual(space(last, 1).focusedColumn, 1)
    }

    func testAnotherWindowLeavingKeepsTheSourceFocusOnItsWindow() {
        var manager = makeManager([[[1], [2], [3]], [[4]]])
        focus(&manager, 1, 3)
        XCTAssertEqual(manager.moveWindowFromOverview(move(1, to: 2, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(focused(manager, 1), 3)
        XCTAssertEqual(space(manager, 1).focusedColumn, 1, "the focused column index shifts with it")
    }

    func testAnEmptiedInactiveSourceDisappearsAndAnEmptiedCurrentOneStays() {
        var inactive = makeManager([[[1]], [[2]]])
        XCTAssertEqual(inactive.moveWindowFromOverview(move(2, to: 1, column: 1), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(inactive, 1), [[1], [2]])
        XCTAssertEqual(inactive.stack(on: display).count, 2, "workspace 2 removed, the spare remains")
        assertInvariants(inactive)

        var current = makeManager([[[1]], [[2]]])
        let shown = current.currentID
        XCTAssertEqual(current.moveWindowFromOverview(move(1, to: 2, column: 1), on: display, modes: [:]), .moved)
        XCTAssertEqual(current.currentID, shown)
        XCTAssertTrue(space(current, 1).columns.isEmpty, "the shown workspace stays until you leave it")
        XCTAssertNil(focused(current, 1))
        XCTAssertEqual(columns(current, 2), [[2], [1]])
        assertInvariants(current)
    }

    func testTheColumnCountsOnlyTheShownColumns() {
        // Column [5] holds only a floating window: the overview does not show it.
        var manager = makeManager([[[1], [5], [2]], [[3]]])
        let modes: [WindowID: WindowMode] = [id(5): .floating]
        XCTAssertEqual(manager.moveWindowFromOverview(move(3, to: 1, column: 2), on: display, modes: modes), .moved)
        XCTAssertEqual(columns(manager, 1), [[1], [5], [2], [3]], "shown column 2 = after window 2")
        var before = makeManager([[[1], [5], [2]], [[3]]])
        XCTAssertEqual(before.moveWindowFromOverview(move(3, to: 1, column: 1), on: display, modes: modes), .moved)
        XCTAssertEqual(columns(before, 1), [[1], [5], [3], [2]], "shown column 1 = before window 2")
    }

    // MARK: - Refusals

    func testRefusalsLeaveTheStateUnchanged() {
        let before = makeManager([[[1], [2]], [[3]]])
        let refused: [(OverviewMove, [WindowID: WindowMode], String)] = [
            (OverviewMove(windowID: "nope", workspace: 1, column: 0), [:], "not a window id"),
            (move(99, to: 1, column: 0), [:], "unknown window"),
            (move(1, to: 2, column: 0), [id(1): .floating], "floating"),
            (move(1, to: 2, column: 0), [id(1): .fullscreen], "fullscreen"),
            (move(1, to: 0, column: 0), [:], "above the stack"),
            (move(1, to: 4, column: 0), [:], "past the stack (2 workspaces and the spare)"),
            (move(1, to: Int.min, column: 0), [:], "no overflow"),
            (move(1, to: 2, column: -1), [:], "negative column"),
            (move(1, to: 2, column: 2), [:], "past the target's columns"),
        ]
        for (request, modes, reason) in refused {
            var manager = before
            XCTAssertEqual(manager.moveWindowFromOverview(request, on: display, modes: modes), .refused, reason)
            XCTAssertEqual(manager, before, reason)
        }
    }

    func testAMinimizedWindowIsRefused() throws {
        let before = makeManager([[[1], [2]], [[3]]])
        let registry = WindowRegistry()
        for element: UInt64 in 1...3 {
            try registry.register(ManagedWindow(
                id: id(element), pid: 10, application: "App", title: "",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .tiled
            ))
        }
        try registry.setMinimized(true, for: id(1))
        var cache = TileabilityCache()
        // The host's modes: a minimized window sits out of the layout.
        let modes = reconcileTileability(registry: registry, cache: &cache) { _ in true }
        var manager = before
        XCTAssertEqual(manager.moveWindowFromOverview(move(1, to: 2, column: 0), on: display, modes: modes), .refused)
        XCTAssertEqual(manager, before)
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 2, column: 0), on: display, modes: modes), .moved)
    }

    func testAWindowOnAnotherDisplaysStackIsRefused() {
        let left = DisplayID(11)
        let right = DisplayID(12)
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        var shown = manager.currentWorkspace()
        shown.columns = [Column(id: ColumnID(1), width: 0, windows: [id(1)])]
        shown.focusedWindow = id(1)
        manager.update(shown)
        XCTAssertTrue(manager.focusDisplay(right))
        var other = manager.currentWorkspace()
        other.columns = [Column(id: ColumnID(1), width: 0, windows: [id(2)])]
        other.focusedWindow = id(2)
        manager.update(other)
        XCTAssertTrue(manager.focusDisplay(left))
        let before = manager
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 1, column: 0), on: left, modes: [:]), .refused)
        XCTAssertEqual(manager, before)
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 2, column: 0), on: right, modes: [:]), .moved)
        XCTAssertEqual(manager.workspace(2, on: right)?.columns.map(\.windows), [[id(2)]])
        XCTAssertEqual(manager.focusedDisplay, left, "the focused display never changes")
    }

    // MARK: - Dwindle (DW-01)

    /// Workspace 2 dwindle: its tree holds exactly its columns, one window each.
    private func assertDwindleInSync(
        _ manager: WorkspaceManager, _ index: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let workspace = space(manager, index)
        XCTAssertEqual(workspace.layout, .dwindle, file: file, line: line)
        XCTAssertEqual(workspace.dwindle.windows, workspace.windows, "tree = columns", file: file, line: line)
        XCTAssertTrue(workspace.columns.allSatisfy { $0.windows.count == 1 }, "one window per column", file: file, line: line)
        if let focused = workspace.focusedWindow {
            XCTAssertEqual(workspace.dwindle.selected, focused, file: file, line: line)
            XCTAssertEqual(workspace.focusedColumnRef?.windows, [focused], file: file, line: line)
        }
    }

    private func dwindleManager() -> WorkspaceManager {
        var manager = makeManager([[[1, 2], [3]], [[4], [5]]])
        XCTAssertTrue(manager.setLayout(.dwindle, of: space(manager, 2).id))
        return manager
    }

    func testIntoADwindleWorkspaceTheTreePlacesTheWindowNextToItsSelectedLeaf() {
        var manager = dwindleManager()
        focus(&manager, 2, 4)
        // Asked for the end: the tree splits the selected (focused) leaf, so
        // the new tile lands right after window 4 in leaf order.
        XCTAssertEqual(manager.moveWindowFromOverview(move(2, to: 2, column: 2), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 2), [[4], [2], [5]])
        XCTAssertEqual(columns(manager, 1), [[1], [3]])
        XCTAssertEqual(focused(manager, 2), 4, "the target's focus does not change")
        assertDwindleInSync(manager, 2)
    }

    func testOutOfADwindleWorkspaceTheTreeCollapsesTheSplit() {
        var manager = dwindleManager()
        XCTAssertEqual(manager.moveWindowFromOverview(move(4, to: 1, column: 0), on: display, modes: [:]), .moved)
        XCTAssertEqual(columns(manager, 1), [[4], [1, 2], [3]])
        XCTAssertEqual(columns(manager, 2), [[5]])
        XCTAssertEqual(focused(manager, 2), 5)
        assertDwindleInSync(manager, 2)
    }

    func testReorderingWithinADwindleWorkspaceIsUnchangedTheTreeKeepsItsOrder() {
        let before = dwindleManager()
        var manager = before
        XCTAssertEqual(manager.moveWindowFromOverview(move(4, to: 2, column: 2), on: display, modes: [:]), .unchanged)
        XCTAssertEqual(manager, before)
        assertDwindleInSync(manager, 2)
    }
}
