import XCTest
@testable import GioCore

/// NF-02: dynamic vertical workspaces — per-display stacks with one trailing
/// empty workspace, empty inactive workspaces removed, stable ids, windows
/// never lost.
final class WorkspaceManagerTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// Put window `n` in a new last column of the current workspace, focused.
    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 300, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func windows(_ manager: WorkspaceManager) -> Set<WindowID> {
        Set(manager.allWorkspaces.flatMap { $0.columns.flatMap(\.windows) })
    }

    private func windowCounts(_ manager: WorkspaceManager, on display: DisplayID = WorkspaceManager.placeholderDisplay) -> [Int] {
        manager.stack(on: display).map { $0.columns.map(\.windows.count).reduce(0, +) }
    }

    /// The invariants every operation must leave behind.
    private func assertInvariants(_ manager: WorkspaceManager, file: StaticString = #filePath, line: UInt = #line) {
        for display in manager.displayIDs {
            let stack = manager.stack(on: display)
            XCTAssertFalse(stack.isEmpty, "empty stack", file: file, line: line)
            XCTAssertTrue(stack.last?.columns.isEmpty ?? false, "no trailing empty workspace", file: file, line: line)
            let active = manager.activeID(on: display)
            for workspace in stack.dropLast() where workspace.columns.isEmpty {
                XCTAssertEqual(workspace.id, active, "empty inactive workspace kept", file: file, line: line)
            }
            XCTAssertEqual(Set(stack.map(\.id)).count, stack.count, "duplicate ids", file: file, line: line)
            XCTAssertNotNil(active.flatMap { a in stack.first { $0.id == a } }, "active not in stack", file: file, line: line)
        }
    }

    func testStartsWithOneEmptyWorkspace() {
        let manager = WorkspaceManager()
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(manager.stack(on: WorkspaceManager.placeholderDisplay).count, 1)
        XCTAssertTrue(manager.currentWorkspace().columns.isEmpty)
        XCTAssertNil(manager.workspace(2))
        XCTAssertNil(manager.workspace(0))
        assertInvariants(manager)
    }

    func testFillingTheSpareGrowsANewSpare() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertEqual(windowCounts(manager), [1, 0])
        assertInvariants(manager)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)
        XCTAssertEqual(windowCounts(manager), [1, 1, 0])
        assertInvariants(manager)
    }

    func testUpdateIgnoresForeignIDs() {
        var manager = WorkspaceManager()
        let foreign = Workspace(id: WorkspaceID(99), columns: [
            Column(id: ColumnID(1), width: 100, windows: [id(1)])
        ])
        manager.update(foreign)
        XCTAssertNil(manager.workspace(id: WorkspaceID(99)))
        XCTAssertTrue(windows(manager).isEmpty)
    }

    func testFocusDownAndUpStopAtTheEnds() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertFalse(manager.focusUp())
        XCTAssertTrue(manager.focusDown())
        XCTAssertEqual(manager.current, 2)
        XCTAssertFalse(manager.focusDown())
        XCTAssertTrue(manager.focusUp())
        XCTAssertEqual(manager.current, 1)
        assertInvariants(manager)
    }

    func testLeavingAnEmptyWorkspaceRemovesIt() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())        // sits on the spare, empty
        XCTAssertEqual(windowCounts(manager), [1, 0])
        XCTAssertTrue(manager.focusUp())          // leaves the spare: it stays (trailing)
        XCTAssertEqual(windowCounts(manager), [1, 0])
        // Empty the top workspace by moving its window down, then leave it.
        XCTAssertTrue(manager.moveWindowDown(id(1)))
        // The emptied top workspace disappears on follow, so the window's
        // workspace shifts up to index 1 (same id as the old spare).
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(windowCounts(manager), [1, 0])
        assertInvariants(manager)
    }

    func testEmptiedFocusedWorkspaceStaysUntilYouLeaveIt() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)                                  // [1, 1, 0], on index 2
        var middle = manager.currentWorkspace()
        middle.stripWindows([id(2)])                      // window closed
        manager.update(middle)
        // The emptied focused workspace is now the last one: it doubles as the
        // spare, so nothing extra is kept below it.
        XCTAssertEqual(windowCounts(manager), [1, 0])
        XCTAssertEqual(manager.current, 2)
        assertInvariants(manager)
        XCTAssertTrue(manager.focusUp())
        XCTAssertEqual(windowCounts(manager), [1, 0])
        assertInvariants(manager)
    }

    func testIdsAreStableWhileIndicesShift() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 3)                                  // [1, 2, 3, spare]
        let third = manager.currentID
        XCTAssertEqual(manager.location(of: third)?.index, 3)
        XCTAssertTrue(manager.switchTo(1))
        var first = manager.currentWorkspace()
        first.stripWindows([id(1)])
        manager.update(first)
        XCTAssertTrue(manager.switchTo(2))                // leaves the emptied first
        XCTAssertEqual(manager.location(of: third)?.index, 2)
        XCTAssertNotNil(manager.workspace(id: third))
        assertInvariants(manager)
    }

    func testMoveWindowDownIntoTheSpareOpensANewSpare() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        put(&manager, 2)
        XCTAssertTrue(manager.moveWindowDown(id(1)))
        XCTAssertEqual(manager.current, 2)                // focus follows
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(windowCounts(manager), [1, 1, 0])
        XCTAssertEqual(windows(manager), [id(1), id(2)])
        assertInvariants(manager)
    }

    func testMoveWindowDownFromTheSpareIsRefused() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())
        XCTAssertFalse(manager.moveWindowDown(id(1)))
        XCTAssertFalse(manager.moveWindowUp(id(99)))
    }

    func testMoveWindowUpFollowsAndRemovesEmptiedSource() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)                                  // [1, 1, spare], on 2
        XCTAssertTrue(manager.moveWindowUp(id(2)))
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(windowCounts(manager), [2, 0])
        XCTAssertFalse(manager.moveWindowUp(id(2)))       // already at the top
        assertInvariants(manager)
    }

    func testIndexMoveKeepsFocusAndCarriesWeight() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        put(&manager, 2)
        var current = manager.currentWorkspace()
        current.columns[0].heightWeights[id(1)] = 2.5
        manager.update(current)
        XCTAssertTrue(manager.moveWindow(id(1), to: 2))   // the spare
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(manager.workspace(2)!.columns[0].heightWeights[id(1)], 2.5)
        XCTAssertEqual(windowCounts(manager), [1, 1, 0])
        assertInvariants(manager)
    }

    func testIndexMoveBeyondTheStackLandsInTheSpare() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.moveWindow(id(1), to: 7))
        XCTAssertEqual(windowCounts(manager), [0, 1, 0])  // emptied focused kept, spare regrown
        XCTAssertEqual(manager.workspace(2)!.focusedWindow, id(1))
        assertInvariants(manager)
    }

    func testIndexMoveRejectsBadMoves() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertFalse(manager.moveWindow(id(1), to: 1))
        XCTAssertFalse(manager.moveWindow(id(1), to: 0))
        XCTAssertFalse(manager.moveWindow(id(99), to: 2))
        XCTAssertEqual(windowCounts(manager), [1, 0])
    }

    func testMovingTheLastWindowResetsSourceFocus() {
        var manager = WorkspaceManager()
        put(&manager, 7)
        XCTAssertTrue(manager.moveWindow(id(7), to: 2))
        let source = manager.workspace(1)!
        XCTAssertTrue(source.columns.isEmpty)
        XCTAssertEqual(source.focusedColumn, 0)
        XCTAssertNil(source.focusedWindow)
    }

    func testIndexJumpBeyondTheStackGoesToTheSpare() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.switchTo(9))
        XCTAssertEqual(manager.current, 2)
        XCTAssertFalse(manager.switchTo(0))
        XCTAssertEqual(manager.current, 2)
        XCTAssertTrue(manager.switchTo(1))
        XCTAssertEqual(manager.current, 1)
        assertInvariants(manager)
    }

    func testRuleTargetClampsToTheSpare() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertEqual(manager.ruleTarget(1), manager.currentID)
        XCTAssertEqual(manager.ruleTarget(5), manager.workspace(2)!.id)
        XCTAssertNil(manager.ruleTarget(0))
    }

    // MARK: - Displays

    func testFirstRealDisplayAdoptsThePlaceholderStack() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        let a = DisplayID(11)
        manager.syncDisplays([a])
        XCTAssertEqual(manager.displayIDs, [a])
        XCTAssertEqual(manager.focusedDisplay, a)
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0])
        assertInvariants(manager)
    }

    func testTheMainDisplayAdoptsThePlaceholderStackWhateverItsPosition() {
        // MM-01: displays arrive ordered by geometry, so the leftmost may be
        // an external one; the session still starts on the main display.
        var manager = WorkspaceManager()
        put(&manager, 1)
        let (left, main) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([left, main], main: main)
        XCTAssertEqual(manager.focusedDisplay, main)
        XCTAssertEqual(windowCounts(manager, on: main), [1, 0])
        XCTAssertEqual(windowCounts(manager, on: left), [0])
        assertInvariants(manager)
    }

    func testEachDisplayKeepsItsOwnStack() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)                                  // focused display a
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0])
        XCTAssertEqual(windowCounts(manager, on: b), [0])
        XCTAssertTrue(manager.focus(manager.activeID(on: b)!))
        XCTAssertEqual(manager.focusedDisplay, b)
        put(&manager, 2)
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0])
        XCTAssertEqual(windowCounts(manager, on: b).reduce(0, +), 1)
        XCTAssertEqual(manager.activeIDs.count, 2)
        assertInvariants(manager)
    }

    func testDisconnectedDisplayMergesItsWindowsIntoTheSurvivor() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        XCTAssertTrue(manager.focus(manager.activeID(on: b)!))
        put(&manager, 2)
        XCTAssertTrue(manager.focus(manager.activeID(on: a)!))
        put(&manager, 1)
        manager.syncDisplays([a])
        XCTAssertEqual(manager.displayIDs, [a])
        XCTAssertEqual(windows(manager), [id(1), id(2)])
        XCTAssertEqual(manager.focusedDisplay, a)
        assertInvariants(manager)
    }

    func testFocusedDisplayRemovedFallsBackToTheSurvivor() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        XCTAssertTrue(manager.focus(manager.activeID(on: b)!))
        put(&manager, 2)
        manager.syncDisplays([a])
        XCTAssertEqual(manager.focusedDisplay, a)
        XCTAssertEqual(windows(manager), [id(2)])
        assertInvariants(manager)
    }

    func testStackSummariesReportEachDisplay() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        let summaries = manager.stackSummaries()
        XCTAssertEqual(summaries.map(\.display), [a, b])
        XCTAssertEqual(summaries.map(\.isFocused), [true, false])
        XCTAssertEqual(summaries[0].workspaces, [
            WorkspaceEntry(index: 1, windows: 1, columns: 1, isActive: true),
            WorkspaceEntry(index: 2, windows: 0, columns: 0, isActive: false),
        ])
        XCTAssertEqual(summaries[1].workspaces, [WorkspaceEntry(index: 1, windows: 0, columns: 0, isActive: true)])
        XCTAssertEqual(summaries[0].activeIndex, 1)
    }

    // MARK: - Monitor actions (MM-02)

    /// Focus the display's shown workspace (the session's click path).
    private func show(_ manager: inout WorkspaceManager, _ display: DisplayID) {
        XCTAssertTrue(manager.focus(manager.activeID(on: display)!))
    }

    /// Make column `index` of the current workspace the focused one.
    private func focusColumn(_ manager: inout WorkspaceManager, _ index: Int) {
        var workspace = manager.currentWorkspace()
        workspace.focusedColumn = index
        workspace.focusedWindow = workspace.columns[index].focusedWindowID
        manager.update(workspace)
    }

    /// Stack window `n` under the focused window's column, focused, with
    /// height weight `weight`.
    private func stack(_ manager: inout WorkspaceManager, _ n: UInt64, weight: CGFloat) {
        var workspace = manager.currentWorkspace()
        workspace.columns[workspace.focusedColumn].windows.append(id(n))
        workspace.columns[workspace.focusedColumn].heightWeights[id(n)] = weight
        workspace.columns[workspace.focusedColumn].focusedWindowIndex =
            workspace.columns[workspace.focusedColumn].windows.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func layout(_ workspace: Workspace?) -> [[WindowID]] {
        workspace?.columns.map(\.windows) ?? []
    }

    func testFocusDisplayShowsItsWorkspaceAndRefusesNoOps() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        let before = manager
        XCTAssertFalse(manager.focusDisplay(a), "already focused")
        XCTAssertFalse(manager.focusDisplay(DisplayID(99)), "unknown display")
        XCTAssertEqual(manager, before)

        XCTAssertTrue(manager.focusDisplay(b))
        XCTAssertEqual(manager.focusedDisplay, b)
        XCTAssertEqual(manager.currentID, before.activeID(on: b))
        XCTAssertNil(manager.currentWorkspace().focusedWindow, "an empty display: no window to focus")
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0], "the other stack is untouched")
        assertInvariants(manager)

        XCTAssertTrue(manager.focusDisplay(a))
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        assertInvariants(manager)
    }

    func testMoveColumnToDisplayLandsAfterTheTargetsFocusedColumnAndFollows() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        show(&manager, b)
        put(&manager, 3)
        put(&manager, 4)
        focusColumn(&manager, 0)
        show(&manager, a)
        put(&manager, 1)
        put(&manager, 2)
        stack(&manager, 5, weight: 2)
        let source = manager.currentID
        let moving = manager.currentWorkspace().columns[1]

        XCTAssertTrue(manager.moveColumn(toDisplay: b))
        XCTAssertEqual(manager.focusedDisplay, b, "focus follows the column")
        let target = manager.currentWorkspace()
        XCTAssertEqual(layout(target), [[id(3)], [id(2), id(5)], [id(4)]])
        XCTAssertEqual(target.focusedColumn, 1)
        XCTAssertEqual(target.focusedWindow, id(5))
        XCTAssertEqual(target.columns[1].widthSpec, moving.widthSpec, "the column keeps its width")
        XCTAssertEqual(target.columns[1].heightWeights, moving.heightWeights)
        XCTAssertEqual(target.columns[1].focusedWindowIndex, 1)
        XCTAssertEqual(Set(target.columns.map(\.id)).count, 3, "column ids stay unique")

        let left = manager.workspace(id: source)
        XCTAssertEqual(layout(left), [[id(1)]])
        XCTAssertEqual(left?.focusedColumn, 0)
        XCTAssertEqual(left?.focusedWindow, id(1), "the source keeps a valid focus")
        XCTAssertEqual(manager.activeID(on: a), source)
        assertInvariants(manager)
    }

    func testMoveColumnIntoAnEmptyDisplayKeepsTheEmptiedSourceShown() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        let source = manager.currentID
        XCTAssertTrue(manager.moveColumn(toDisplay: b))
        XCTAssertEqual(layout(manager.currentWorkspace()), [[id(1)]])
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(windowCounts(manager, on: b), [1, 0], "the filled spare grows a new spare")
        // Like niri, the emptied workspace stays on its display until you leave it.
        XCTAssertEqual(manager.activeID(on: a), source)
        XCTAssertNil(manager.workspace(id: source)?.focusedWindow)
        XCTAssertEqual(manager.workspace(id: source)?.focusedColumn, 0)
        assertInvariants(manager)
    }

    func testMoveColumnAndWindowToDisplayRefuseNoOps() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        var before = manager
        XCTAssertFalse(manager.moveColumn(toDisplay: b), "nothing to move")
        XCTAssertFalse(manager.moveWindow(toDisplay: b), "nothing to move")
        put(&manager, 1)
        before = manager
        XCTAssertFalse(manager.moveColumn(toDisplay: a), "same display")
        XCTAssertFalse(manager.moveWindow(toDisplay: a), "same display")
        XCTAssertFalse(manager.moveColumn(toDisplay: DisplayID(99)), "unknown display")
        XCTAssertFalse(manager.moveWindow(toDisplay: DisplayID(99)), "unknown display")
        XCTAssertEqual(manager, before)
    }

    func testMoveWindowToDisplayMovesOnlyTheFocusedWindowAsItsOwnColumn() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        show(&manager, b)
        put(&manager, 3)
        put(&manager, 4)
        focusColumn(&manager, 0)
        show(&manager, a)
        put(&manager, 1)
        put(&manager, 2)
        stack(&manager, 5, weight: 2)
        let source = manager.currentID

        XCTAssertTrue(manager.moveWindow(toDisplay: b))
        XCTAssertEqual(manager.focusedDisplay, b)
        let target = manager.currentWorkspace()
        XCTAssertEqual(layout(target), [[id(3)], [id(5)], [id(4)]])
        XCTAssertEqual(target.focusedColumn, 1)
        XCTAssertEqual(target.focusedWindow, id(5))
        XCTAssertEqual(target.columns[1].widthSpec, .standard, "a new column at the default width")
        XCTAssertEqual(Set(target.columns.map(\.id)).count, 3)

        let left = manager.workspace(id: source)
        XCTAssertEqual(layout(left), [[id(1)], [id(2)]], "the rest of the column stays")
        XCTAssertEqual(left?.focusedColumn, 1)
        XCTAssertEqual(left?.focusedWindow, id(2))
        assertInvariants(manager)
    }

    func testMoveWindowToDisplayWithoutAFocusedWindowIsRefused() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        var workspace = manager.currentWorkspace()
        workspace.focusedWindow = nil
        manager.update(workspace)
        let before = manager
        XCTAssertFalse(manager.moveWindow(toDisplay: b))
        XCTAssertEqual(manager, before)
    }

    func testThreeDisplaysMoveAcrossLeavesTheMiddleAlone() {
        var manager = WorkspaceManager()
        let (a, b, c) = (DisplayID(11), DisplayID(12), DisplayID(13))
        manager.syncDisplays([a, b, c])
        show(&manager, b)
        put(&manager, 2)
        show(&manager, a)
        put(&manager, 1)
        let middle = manager.stack(on: b)

        XCTAssertTrue(manager.moveColumn(toDisplay: c))
        XCTAssertEqual(manager.focusedDisplay, c)
        XCTAssertEqual(windowCounts(manager, on: c), [1, 0])
        XCTAssertEqual(manager.stack(on: b), middle)
        assertInvariants(manager)

        XCTAssertTrue(manager.moveWorkspace(toDisplay: a))
        XCTAssertEqual(manager.focusedDisplay, a)
        XCTAssertEqual(layout(manager.currentWorkspace()), [[id(1)]])
        XCTAssertEqual(windowCounts(manager, on: c), [0])
        XCTAssertEqual(manager.stack(on: b), middle)
        XCTAssertEqual(windows(manager), [id(1), id(2)])
        assertInvariants(manager)
    }

    func testMoveWorkspaceToDisplayLandsAfterTheTargetsActiveAndShowsTheOneBelow() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        show(&manager, b)
        put(&manager, 3)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 4)
        XCTAssertTrue(manager.focusUp())                     // b: [3]*, [4], spare
        show(&manager, a)
        put(&manager, 1)
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)
        XCTAssertTrue(manager.focusUp())                     // a: [1]*, [2], spare
        let moving = manager.currentID
        let below = manager.workspace(2)!.id

        XCTAssertTrue(manager.moveWorkspace(toDisplay: b))
        XCTAssertEqual(manager.focusedDisplay, b)
        XCTAssertEqual(manager.currentID, moving, "the moved workspace is shown and focused")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(manager.stack(on: b).map(layout), [[[id(3)]], [[id(1)]], [[id(4)]], []])
        XCTAssertEqual(manager.current, 2)
        XCTAssertEqual(manager.activeID(on: a), below, "the source shows its neighbour below")
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0])
        assertInvariants(manager)
    }

    func testMoveWorkspaceShowsTheOneAboveWhenOnlyTheSpareIsBelow() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        let above = manager.currentID
        XCTAssertTrue(manager.focusDown())
        put(&manager, 2)                                     // a: [1], [2]*, spare
        XCTAssertTrue(manager.moveWorkspace(toDisplay: b))
        XCTAssertEqual(manager.activeID(on: a), above)
        XCTAssertEqual(windowCounts(manager, on: a), [1, 0])
        assertInvariants(manager)
    }

    func testMovingTheOnlyNonEmptyWorkspaceLeavesTheSourceOnItsEmptyOne() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        let moving = manager.currentID
        XCTAssertTrue(manager.moveWorkspace(toDisplay: b))
        XCTAssertEqual(windowCounts(manager, on: a), [0], "only the empty spare is left")
        XCTAssertEqual(manager.stack(on: b).first?.id, moving, "above the target's spare")
        XCTAssertEqual(windowCounts(manager, on: b), [1, 0])
        XCTAssertEqual(manager.currentID, moving)
        assertInvariants(manager)
    }

    func testMoveWorkspaceToDisplayRefusesNoOps() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        var before = manager
        XCTAssertFalse(manager.moveWorkspace(toDisplay: b), "an empty workspace carries nothing")
        XCTAssertEqual(manager, before)
        put(&manager, 1)
        before = manager
        XCTAssertFalse(manager.moveWorkspace(toDisplay: a), "same display")
        XCTAssertFalse(manager.moveWorkspace(toDisplay: DisplayID(99)), "unknown display")
        XCTAssertEqual(manager, before)
    }

    // MARK: - Property

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testRandomOperationsKeepInvariantsAndNeverLoseWindows() {
        var rng = SeededGenerator(state: 0xC0FFEE)
        var manager = WorkspaceManager()
        var live = Set<WindowID>()
        var nextWindow: UInt64 = 1
        let displays = [DisplayID(21), DisplayID(22), DisplayID(23)]
        manager.syncDisplays(displays)
        for step in 0..<3000 {
            switch Int.random(in: 0..<14, using: &rng) {
            case 0, 1:
                put(&manager, nextWindow)
                live.insert(id(nextWindow))
                nextWindow += 1
            case 2: manager.focusDown()
            case 3: manager.focusUp()
            case 4:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindowDown(focused)
                }
            case 5:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindowUp(focused)
                }
            case 6:
                manager.switchTo(Int.random(in: 0...10, using: &rng))
            case 7:
                if let focused = manager.currentWorkspace().focusedWindow {
                    manager.moveWindow(focused, to: Int.random(in: 0...10, using: &rng))
                }
            case 8:
                if let victim = live.randomElement(using: &rng) {
                    for var workspace in manager.allWorkspaces where workspace.columns.contains(where: { $0.windows.contains(victim) }) {
                        workspace.stripWindows([victim])
                        manager.update(workspace)
                    }
                    live.remove(victim)
                }
            case 10: manager.focusDisplay(displays.randomElement(using: &rng)!)
            case 11: manager.moveColumn(toDisplay: displays.randomElement(using: &rng)!)
            case 12: manager.moveWindow(toDisplay: displays.randomElement(using: &rng)!)
            case 13: manager.moveWorkspace(toDisplay: displays.randomElement(using: &rng)!)
            default:
                let target = displays.randomElement(using: &rng)!
                manager.focus(manager.activeID(on: target)!)
            }
            assertInvariants(manager)
            XCTAssertEqual(windows(manager), live, "window set drifted at step \(step)")
        }
        manager.syncDisplays([displays[1]])
        XCTAssertEqual(windows(manager), live)
        assertInvariants(manager)
    }
}
