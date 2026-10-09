import XCTest
@testable import GioCore

/// NC-10/NC-11: niri `move-column-to-workspace N|up|down` (the whole column,
/// focus follows), `focus-workspace-previous` (per-display history) and
/// `move-workspace-up/down` (reorder the display's stack; named workspaces
/// keep their config order and refuse).
final class WorkspaceColumnActionsTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func defs(_ names: String...) -> [WorkspaceDefinition] {
        names.map { WorkspaceDefinition(name: $0) }
    }

    /// Put window `n` in a new last column of the current workspace, focused.
    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 300, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    /// Stack window `n` under the focused column, focused, with `weight`.
    private func stack(_ manager: inout WorkspaceManager, _ n: UInt64, weight: CGFloat) {
        var workspace = manager.currentWorkspace()
        workspace.columns[workspace.focusedColumn].windows.append(id(n))
        workspace.columns[workspace.focusedColumn].heightWeights[id(n)] = weight
        workspace.columns[workspace.focusedColumn].focusedWindowIndex =
            workspace.columns[workspace.focusedColumn].windows.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func focusColumn(_ manager: inout WorkspaceManager, _ index: Int) {
        var workspace = manager.currentWorkspace()
        workspace.focusedColumn = index
        workspace.focusedWindow = workspace.columns[index].focusedWindowID
        manager.update(workspace)
    }

    private func layouts(_ manager: WorkspaceManager, on display: DisplayID = WorkspaceManager.placeholderDisplay) -> [[[WindowID]]] {
        manager.stack(on: display).map { $0.columns.map(\.windows) }
    }

    private func names(_ manager: WorkspaceManager, on display: DisplayID = WorkspaceManager.placeholderDisplay) -> [String?] {
        manager.stack(on: display).map(\.name)
    }

    private func assertInvariants(_ manager: WorkspaceManager, file: StaticString = #filePath, line: UInt = #line) {
        for display in manager.displayIDs {
            let stack = manager.stack(on: display)
            XCTAssertTrue(stack.last?.columns.isEmpty ?? false, "no trailing empty workspace", file: file, line: line)
            XCTAssertNil(stack.last?.name, "spare must be dynamic", file: file, line: line)
            let active = manager.activeID(on: display)
            for workspace in stack.dropLast() where workspace.columns.isEmpty && workspace.name == nil {
                XCTAssertEqual(workspace.id, active, "empty inactive workspace kept", file: file, line: line)
            }
            let namedPrefix = stack.prefix { $0.name != nil }.count
            XCTAssertEqual(stack.filter { $0.name != nil }.count, namedPrefix, "named not first", file: file, line: line)
        }
    }

    /// Workspace 1: `[1] [2 5*]`; workspace 2: `[3]`; then the spare. The
    /// stacked column of workspace 1 is focused.
    private func twoWorkspaces() -> WorkspaceManager {
        var manager = WorkspaceManager()
        put(&manager, 1)
        put(&manager, 2)
        stack(&manager, 5, weight: 2)
        XCTAssertTrue(manager.switchTo(2))
        put(&manager, 3)
        XCTAssertTrue(manager.switchTo(1))
        return manager
    }

    // MARK: move-column-to-workspace

    func testMoveColumnToWorkspaceNCarriesTheWholeColumnAndFollows() {
        var manager = twoWorkspaces()
        XCTAssertEqual(layouts(manager), [[[id(1)], [id(2), id(5)]], [[id(3)]], []])
        let moving = manager.currentWorkspace().columns[1]

        XCTAssertTrue(manager.moveColumn(toWorkspace: 2))
        XCTAssertEqual(manager.current, 2, "focus follows the column (niri focus=true)")
        XCTAssertEqual(layouts(manager), [[[id(1)]], [[id(3)], [id(2), id(5)]], []])
        let target = manager.currentWorkspace()
        XCTAssertEqual(target.focusedColumn, 1, "lands right of the target's focused column")
        XCTAssertEqual(target.focusedWindow, id(5))
        XCTAssertEqual(target.columns[1].widthSpec, moving.widthSpec)
        XCTAssertEqual(target.columns[1].heightWeights, moving.heightWeights)
        XCTAssertEqual(target.columns[1].focusedWindowIndex, 1)
        XCTAssertEqual(Set(target.columns.map(\.id)).count, 2, "fresh column id")
        XCTAssertEqual(manager.workspace(1)?.focusedWindow, id(1), "the source repairs its focus")
        assertInvariants(manager)
    }

    func testMoveColumnBeyondTheStackOpensAWorkspaceAndPrunesTheEmptiedSource() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        XCTAssertTrue(manager.moveColumn(toWorkspace: 9))
        XCTAssertEqual(layouts(manager), [[[id(1)]], []], "the emptied source is gone")
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        assertInvariants(manager)
    }

    func testMoveColumnToTheSameWorkspaceOrWithoutAColumnIsRefused() {
        var manager = twoWorkspaces()
        let before = manager
        XCTAssertFalse(manager.moveColumn(toWorkspace: 1), "already there")
        XCTAssertFalse(manager.moveColumn(toWorkspace: 0))
        XCTAssertEqual(manager, before)
        var empty = WorkspaceManager()
        let untouched = empty
        XCTAssertFalse(empty.moveColumn(toWorkspace: 2))
        XCTAssertFalse(empty.moveColumnToWorkspaceDown())
        XCTAssertEqual(empty, untouched)
    }

    func testMoveColumnToWorkspaceDownAndUpFollowTheColumn() {
        var manager = twoWorkspaces()
        XCTAssertFalse(manager.moveColumnToWorkspaceUp(), "top of the stack")
        XCTAssertTrue(manager.moveColumnToWorkspaceDown())
        XCTAssertEqual(manager.current, 2)
        XCTAssertEqual(layouts(manager), [[[id(1)]], [[id(3)], [id(2), id(5)]], []])
        XCTAssertTrue(manager.moveColumnToWorkspaceDown(), "into the spare: a new workspace")
        XCTAssertEqual(manager.current, 3)
        XCTAssertEqual(layouts(manager), [[[id(1)]], [[id(3)]], [[id(2), id(5)]], []])
        XCTAssertTrue(manager.moveColumnToWorkspaceUp())
        XCTAssertEqual(manager.current, 2)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5))
        XCTAssertEqual(layouts(manager), [[[id(1)]], [[id(3)], [id(2), id(5)]], []], "the emptied workspace is pruned")
        assertInvariants(manager)
    }

    // MARK: focus-workspace-previous

    func testFocusWorkspacePreviousTogglesBetweenTheLastTwo() {
        var fresh = WorkspaceManager()
        put(&fresh, 1)
        let untouched = fresh
        XCTAssertFalse(fresh.focusWorkspacePrevious(), "no history yet")
        XCTAssertEqual(fresh, untouched)

        var manager = twoWorkspaces()
        XCTAssertTrue(manager.focusWorkspacePrevious(), "built by visiting 2, then 1")
        XCTAssertEqual(manager.current, 2)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        XCTAssertTrue(manager.focusWorkspacePrevious())
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5))
        manager.switchTo(1)
        XCTAssertTrue(manager.focusWorkspacePrevious(), "re-selecting the shown workspace keeps the history")
        XCTAssertEqual(manager.current, 2)
    }

    func testFocusWorkspacePreviousIsPerDisplay() {
        var manager = WorkspaceManager()
        let (a, b) = (DisplayID(11), DisplayID(12))
        manager.syncDisplays([a, b])
        put(&manager, 1)
        manager.switchTo(2)
        put(&manager, 2)
        XCTAssertTrue(manager.focusDisplay(b))
        put(&manager, 3)
        XCTAssertFalse(manager.focusWorkspacePrevious(), "display b has no history of its own")
        XCTAssertTrue(manager.focusDisplay(a))
        XCTAssertTrue(manager.focusWorkspacePrevious())
        XCTAssertEqual(manager.focusedDisplay, a)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(manager.activeID(on: b), manager.stack(on: b).first?.id, "display b untouched")
    }

    func testFocusWorkspacePreviousReachesEmptyNamedWorkspacesButNotPrunedOnes() {
        var named = WorkspaceManager()
        named.applyNamedWorkspaces(defs("Code", "Chat"))
        XCTAssertTrue(named.switchTo(2))
        XCTAssertTrue(named.focusWorkspacePrevious())
        XCTAssertEqual(named.currentWorkspace().name, "Code", "an empty named workspace is kept, so it is reachable")
        XCTAssertTrue(named.focusWorkspacePrevious())
        XCTAssertEqual(named.currentWorkspace().name, "Chat")

        var pruned = WorkspaceManager()
        put(&pruned, 1)
        XCTAssertTrue(pruned.moveWindowDown(id(1)), "workspace 1 empties and is left")
        XCTAssertEqual(pruned.current, 1, "the emptied source was pruned")
        let before = pruned
        XCTAssertFalse(pruned.focusWorkspacePrevious(), "the previous workspace no longer exists")
        XCTAssertEqual(pruned, before)
    }

    // MARK: move-workspace-up / -down

    func testMoveWorkspaceDownAndUpReorderTheStackAndKeepItShown() {
        var manager = twoWorkspaces()
        let shown = manager.currentID
        XCTAssertFalse(manager.moveWorkspaceUp(), "already first")
        XCTAssertTrue(manager.moveWorkspaceDown())
        XCTAssertEqual(manager.currentID, shown, "the same workspace stays shown")
        XCTAssertEqual(manager.current, 2)
        XCTAssertEqual(layouts(manager), [[[id(3)]], [[id(1)], [id(2), id(5)]], []])
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5))
        XCTAssertFalse(manager.moveWorkspaceDown(), "never below the trailing spare")
        XCTAssertTrue(manager.moveWorkspaceUp())
        XCTAssertEqual(manager.current, 1)
        XCTAssertEqual(layouts(manager), [[[id(1)], [id(2), id(5)]], [[id(3)]], []])
        assertInvariants(manager)
    }

    func testMoveWorkspaceRefusesNamedWorkspacesAndNeverPassesAboveThem() {
        var manager = WorkspaceManager()
        manager.applyNamedWorkspaces(defs("Code", "Chat"))
        put(&manager, 1)
        let before = manager
        XCTAssertFalse(manager.moveWorkspaceDown(), "a named workspace keeps its config order")
        XCTAssertFalse(manager.moveWorkspaceUp())
        XCTAssertEqual(manager, before)
        manager.switchTo(3)
        put(&manager, 2)
        manager.switchTo(4)
        put(&manager, 3)
        XCTAssertEqual(names(manager), ["Code", "Chat", nil, nil, nil])
        XCTAssertTrue(manager.moveWorkspaceUp())
        XCTAssertEqual(manager.current, 3)
        XCTAssertEqual(layouts(manager)[2], [[id(3)]])
        XCTAssertFalse(manager.moveWorkspaceUp(), "dynamic workspaces stay below the named ones")
        XCTAssertEqual(names(manager), ["Code", "Chat", nil, nil, nil])
        assertInvariants(manager)
    }

    func testMoveWorkspaceRefusesAnEmptyWorkspace() {
        var manager = twoWorkspaces()
        manager.switchTo(3)
        let before = manager
        XCTAssertFalse(manager.moveWorkspaceUp(), "the spare carries nothing")
        XCTAssertEqual(manager, before)
    }
}
