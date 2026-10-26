import XCTest
@testable import GioCore

/// DW-01: the columns stay the one membership list and the dwindle tree is
/// a view of them, kept in sync on every `WorkspaceManager` write. Every
/// arrival and removal path keeps the tree and the membership consistent,
/// and switching layouts never loses or duplicates a window.
final class DwindleMembershipTests: XCTestCase {
    private let left = DisplayID(11)
    private let right = DisplayID(12)

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func ids(_ elements: UInt64...) -> [WindowID] {
        elements.map(id)
    }

    /// Append `n` as its own focused column of the current workspace.
    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 0, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func focus(_ manager: inout WorkspaceManager, _ n: UInt64) {
        let adopted = adoptingFocus(id(n), in: manager.currentWorkspace())!
        manager.update(adopted)
    }

    /// A dwindle current workspace holding windows 1...count (spiral).
    private func dwindleManager(_ count: UInt64) -> WorkspaceManager {
        var manager = WorkspaceManager()
        XCTAssertTrue(manager.setLayout(.dwindle))
        for n in 1...count {
            put(&manager, n)
        }
        return manager
    }

    /// Every workspace: a dwindle tree holds exactly the column windows, in
    /// column order, one window per column, selection on the focused
    /// window; a scrolling workspace has no tree; no window is anywhere twice.
    private func assertConsistent(
        _ manager: WorkspaceManager, file: StaticString = #filePath, line: UInt = #line
    ) {
        var seen: [WindowID] = []
        for workspace in manager.allWorkspaces {
            seen += workspace.windows
            switch workspace.layout {
            case .scrolling:
                XCTAssertEqual(workspace.dwindle, DwindleState(), "scrolling keeps no tree", file: file, line: line)
            case .dwindle:
                XCTAssertEqual(workspace.dwindle.windows, workspace.windows, "tree = columns", file: file, line: line)
                XCTAssertTrue(workspace.columns.allSatisfy { $0.windows.count == 1 }, "one window per column", file: file, line: line)
                if let focused = workspace.focusedWindow {
                    XCTAssertEqual(workspace.dwindle.selected, focused, file: file, line: line)
                    XCTAssertEqual(workspace.focusedColumnRef?.windows, [focused], file: file, line: line)
                }
            }
        }
        XCTAssertEqual(seen.count, Set(seen).count, "a window in two places", file: file, line: line)
    }

    // MARK: - Layout switch

    func testSwitchingToDwindleAndBackKeepsEveryWindowAndTheFocus() {
        var manager = WorkspaceManager()
        var workspace = manager.currentWorkspace()
        workspace.columns = [
            Column(id: ColumnID(1), width: 0, windows: ids(1, 2), focusedWindowIndex: 1, heightWeights: [id(1): 2]),
            Column(id: ColumnID(2), width: 0, windows: ids(3)),
            Column(id: ColumnID(3), width: 0, windows: ids(4), widthSpec: .proportion(0.75)),
        ]
        workspace.focusedColumn = 1
        workspace.focusedWindow = id(3)
        manager.update(workspace)
        let before = Set(manager.currentWorkspace().windows)

        XCTAssertTrue(manager.setLayout(.dwindle))
        var now = manager.currentWorkspace()
        XCTAssertEqual(now.layout, .dwindle)
        XCTAssertEqual(Set(now.windows), before)
        XCTAssertEqual(now.dwindle.windows, ids(1, 2, 3, 4), "built from the column order")
        XCTAssertEqual(now.focusedWindow, id(3))
        XCTAssertEqual(now.viewportOffset, 0)
        XCTAssertEqual(now.columns.first { $0.windows == [id(4)] }?.widthSpec, .proportion(0.75), "a column keeps its width")
        assertConsistent(manager)
        XCTAssertFalse(manager.setLayout(.dwindle), "already dwindle: no-op")

        XCTAssertTrue(manager.setLayout(.scrolling))
        now = manager.currentWorkspace()
        XCTAssertEqual(now.layout, .scrolling)
        XCTAssertEqual(Set(now.windows), before)
        XCTAssertEqual(now.columns.map(\.windows), [ids(1), ids(2), ids(3), ids(4)], "one column per window, tree order")
        XCTAssertEqual(now.focusedWindow, id(3))
        XCTAssertEqual(now.focusedColumnRef?.windows, ids(3))
        assertConsistent(manager)

        XCTAssertTrue(manager.toggleLayout())
        XCTAssertEqual(manager.currentWorkspace().layout, .dwindle)
        XCTAssertEqual(Set(manager.currentWorkspace().windows), before)
        assertConsistent(manager)
    }

    func testTheDwindleTreeFollowsTheTreeOrderBackIntoScrollingColumns() {
        var manager = dwindleManager(3)
        var workspace = manager.currentWorkspace()
        workspace.dwindle.root = workspace.dwindle.root?.swappingLeaves(id(1), id(3))
        manager.update(workspace)
        XCTAssertEqual(manager.currentWorkspace().windows, ids(3, 2, 1))
        XCTAssertTrue(manager.setLayout(.scrolling))
        XCTAssertEqual(manager.currentWorkspace().columns.map(\.windows), [ids(3), ids(2), ids(1)])
    }

    func testSettingTheLayoutOfAnotherWorkspaceById() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        // The trailing spare (leaving an empty workspace would prune it).
        let second = manager.workspace(2)!.id
        XCTAssertTrue(manager.setLayout(.dwindle, of: second))
        XCTAssertEqual(manager.workspace(id: second)?.layout, .dwindle)
        XCTAssertEqual(manager.currentWorkspace().layout, .scrolling)
        XCTAssertFalse(manager.setLayout(.dwindle, of: WorkspaceID(999)))
    }

    // MARK: - The manager keeps the tree in sync

    func testAnUpdateWithAStaleTreeIsRepaired() {
        var manager = dwindleManager(2)
        var workspace = manager.currentWorkspace()
        workspace.dwindle.root = .split(DwindleSplit(first: .leaf(id(1)), second: .leaf(id(99))))
        workspace.columns.append(Column(id: ColumnID(3), width: 0, windows: ids(3)))
        manager.update(workspace)
        XCTAssertEqual(Set(manager.currentWorkspace().dwindle.windows), Set(ids(1, 2, 3)))
        assertConsistent(manager)
    }

    func testAScrollingWorkspaceNeverKeepsATree() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        var workspace = manager.currentWorkspace()
        workspace.dwindle = DwindleState(root: .leaf(id(1)))
        manager.update(workspace)
        XCTAssertEqual(manager.currentWorkspace().dwindle, DwindleState())
    }

    func testReconcileIsIdempotent() {
        let manager = dwindleManager(4)
        var workspace = manager.currentWorkspace()
        workspace.reconcileDwindle(splitRatio: 1)
        XCTAssertEqual(workspace, manager.currentWorkspace())
    }

    // MARK: - Arrivals

    func testANewWindowSplitsThePreviouslyFocusedWindow() {
        var manager = dwindleManager(3)
        focus(&manager, 1)
        placeArrival(id(4), outcome: RuleOutcome(), takesFocus: true, manager: &manager)
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.dwindle.windows, ids(1, 4, 2, 3))
        XCTAssertEqual(workspace.dwindle.root?.path(to: id(4)), [.first, .second])
        XCTAssertEqual(workspace.focusedWindow, id(4))
        assertConsistent(manager)
    }

    func testAnArrivalThatDoesNotTakeFocusSplitsTheFocusedWindow() {
        var manager = dwindleManager(3)
        focus(&manager, 2)
        placeArrival(id(4), outcome: RuleOutcome(), takesFocus: false, manager: &manager)
        let workspace = manager.currentWorkspace()
        XCTAssertEqual(workspace.dwindle.windows, ids(1, 2, 4, 3))
        XCTAssertEqual(workspace.focusedWindow, id(2))
        assertConsistent(manager)
    }

    func testAPreselectionDecidesWhereTheNextArrivalGoes() {
        var manager = dwindleManager(1)
        var workspace = manager.currentWorkspace()
        workspace.dwindle.preselection = .left
        manager.update(workspace)
        placeArrival(id(2), outcome: RuleOutcome(), takesFocus: true, manager: &manager)
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows, ids(2, 1))
        XCTAssertNil(manager.currentWorkspace().dwindle.preselection)
    }

    func testARuleArrivalOnAnotherDwindleWorkspaceJoinsItsTree() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        manager.switchTo(2)
        XCTAssertTrue(manager.setLayout(.dwindle))
        put(&manager, 2)
        let target = manager.currentID
        manager.switchTo(1)
        placeArrival(id(3), outcome: RuleOutcome(workspace: 2), takesFocus: true, manager: &manager)
        XCTAssertEqual(manager.workspace(id: target)?.dwindle.windows, ids(2, 3))
        XCTAssertEqual(manager.currentWorkspace().windows, ids(1), "the current workspace keeps its strip")
        assertConsistent(manager)
    }

    func testAMultiWindowColumnArrivingFromScrollingSplitsIntoOneTilePerWindow() {
        var manager = WorkspaceManager()
        var workspace = manager.currentWorkspace()
        workspace.columns = [Column(id: ColumnID(1), width: 0, windows: ids(1, 2), focusedWindowIndex: 1)]
        workspace.focusedWindow = id(2)
        manager.update(workspace)
        manager.switchTo(2)
        XCTAssertTrue(manager.setLayout(.dwindle))
        put(&manager, 3)
        let dwindle = manager.currentID
        manager.switchTo(1)
        XCTAssertTrue(manager.moveColumn(toWorkspace: 2))
        let landed = manager.workspace(id: dwindle)!
        XCTAssertEqual(Set(landed.dwindle.windows), Set(ids(1, 2, 3)))
        XCTAssertEqual(landed.focusedWindow, id(2))
        assertConsistent(manager)
    }

    // MARK: - Removals

    func testClosingAWindowCollapsesItsSplitAndRepairsTheFocus() {
        var manager = dwindleManager(3)
        var workspace = manager.currentWorkspace()
        workspace.stripWindows([id(3)])
        manager.update(workspace)
        let now = manager.currentWorkspace()
        XCTAssertEqual(now.dwindle.root, .split(DwindleSplit(first: .leaf(id(1)), second: .leaf(id(2)))))
        XCTAssertEqual(now.focusedWindow, id(2))
        assertConsistent(manager)
    }

    func testRecoveryPruningKeepsTheTreeConsistent() throws {
        let registry = WindowRegistry()
        for n in UInt64(1)...3 {
            try registry.register(ManagedWindow(
                id: id(n), pid: 10, application: "App", title: "t\(n)",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300), mode: .tiled
            ))
        }
        var state = RecoveryState(registry: registry, manager: dwindleManager(3), displays: DisplayManager())
        recover(state: &state, input: RecoveryInput(liveIDs: [id(3)]))
        XCTAssertEqual(state.manager.currentWorkspace().dwindle.root, .leaf(id(3)))
        assertConsistent(state.manager)
    }

    func testMinimizeKeepsTheLeafAndRestoreBringsTheTileBack() throws {
        let registry = WindowRegistry()
        for n in UInt64(1)...3 {
            try registry.register(ManagedWindow(
                id: id(n), pid: 10, application: "App", title: "t\(n)",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300), mode: .tiled
            ))
        }
        var manager = dwindleManager(3)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
        func plan() throws -> DisplayLayoutPlan {
            var cache = TileabilityCache()
            let modes = reconcileTileability(registry: registry, cache: &cache, now: 0) { _ in .tileable }.modes
            return try planDisplayLayout(
                workspace: manager.currentWorkspace(), modes: modes, engine: engine,
                viewport: viewport, display: viewport, otherDisplays: []
            )
        }
        let before = try plan().plan.visible

        XCTAssertTrue(minimizeWindow(id(3), registry: registry, manager: &manager))
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows, ids(1, 2, 3), "the leaf stays (position memory)")
        XCTAssertNotEqual(manager.currentWorkspace().focusedWindow, id(3))
        assertConsistent(manager)
        let minimized = try plan().plan.visible
        XCTAssertNil(minimized[id(3)])
        XCTAssertEqual(minimized[id(2)], CGRect(x: 505, y: 10, width: 485, height: 580), "the sibling takes the space")

        XCTAssertTrue(restoreWindow(id(3), registry: registry, manager: &manager))
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        XCTAssertEqual(try plan().plan.visible, before, "the tile comes back where it was")
        assertConsistent(manager)
    }

    // MARK: - Moves between workspaces and displays

    func testMovingWindowsBetweenDwindleAndScrollingWorkspaces() {
        var manager = dwindleManager(3)
        XCTAssertTrue(manager.moveWindow(id(3), to: 2))
        assertConsistent(manager)
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows, ids(1, 2))
        XCTAssertEqual(manager.workspace(2)?.windows, ids(3))
        XCTAssertEqual(manager.workspace(2)?.layout, .scrolling)

        XCTAssertTrue(manager.moveWindowDown(id(2)))
        assertConsistent(manager)
        XCTAssertEqual(manager.currentWorkspace().windows.sorted(), ids(2, 3))
        XCTAssertTrue(manager.setLayout(.dwindle))
        XCTAssertTrue(manager.moveColumnToWorkspaceUp())
        assertConsistent(manager)
        let all = manager.allWorkspaces.flatMap(\.windows)
        XCTAssertEqual(all.sorted(), ids(1, 2, 3))
    }

    func testDisplayMovesKeepBothTreesConsistent() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        XCTAssertTrue(manager.setLayout(.dwindle))
        put(&manager, 1)
        put(&manager, 2)
        put(&manager, 3)
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        XCTAssertTrue(manager.setLayout(.dwindle))
        put(&manager, 4)
        XCTAssertTrue(manager.focus(manager.activeID(on: left)!))

        XCTAssertTrue(manager.moveColumn(toDisplay: right))
        assertConsistent(manager)
        XCTAssertEqual(manager.focusedDisplay, right)
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows, ids(4, 3))

        XCTAssertTrue(manager.moveWindow(toDisplay: left))
        assertConsistent(manager)
        XCTAssertEqual(manager.workspace(id: manager.activeID(on: left)!)?.dwindle.windows.count, 3)

        XCTAssertTrue(manager.moveWorkspace(toDisplay: right))
        assertConsistent(manager)
        XCTAssertEqual(manager.allWorkspaces.flatMap(\.windows).sorted(), ids(1, 2, 3, 4))
    }

    func testARemovedDisplayMergesItsDwindleWorkspaceIntact() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        XCTAssertTrue(manager.setLayout(.dwindle))
        put(&manager, 1)
        put(&manager, 2)
        let moved = manager.currentID
        let tree = manager.currentWorkspace().dwindle
        manager.syncDisplays([left])
        XCTAssertEqual(manager.workspace(id: moved)?.dwindle, tree)
        XCTAssertEqual(manager.workspace(id: moved)?.layout, .dwindle)
        assertConsistent(manager)
    }

    // MARK: - Defaults

    func testNewWorkspacesTakeTheDefaultLayoutAndEmptyOnesAdoptAChange() {
        var manager = WorkspaceManager()
        put(&manager, 1)
        manager.applyLayoutDefaults(WorkspaceLayoutDefaults(kind: .dwindle, splitRatio: 1.4))
        XCTAssertEqual(manager.currentWorkspace().layout, .scrolling, "a workspace with windows keeps its layout")
        XCTAssertEqual(manager.workspace(2)?.layout, .dwindle, "the empty spare adopts the default")
        manager.switchTo(2)
        put(&manager, 2)
        XCTAssertEqual(manager.workspace(3)?.layout, .dwindle, "a new spare is created with the default")
        put(&manager, 3)
        guard case .split(let split)? = manager.currentWorkspace().dwindle.root else {
            return XCTFail("two windows split")
        }
        XCTAssertEqual(split.ratio, 1.4, "new splits use default-split-ratio")
        manager.applyLayoutDefaults(WorkspaceLayoutDefaults())
        XCTAssertEqual(manager.currentWorkspace().layout, .dwindle, "a non-empty workspace keeps its layout")
        assertConsistent(manager)
    }

    // MARK: - Planning

    func testTheFirstLayoutPinsEachShownSplitToItsShape() throws {
        let manager = dwindleManager(3)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
        func plannedRoot(_ modes: [WindowID: WindowMode]) throws -> DwindleSplit? {
            let planned = try planDisplayLayout(
                workspace: manager.currentWorkspace(), modes: modes, engine: engine,
                viewport: viewport, display: viewport, otherDisplays: []
            )
            guard case .split(let root)? = planned.workspace.dwindle.root else {
                return nil
            }
            return root
        }
        let shown = try XCTUnwrap(plannedRoot([:]))
        XCTAssertEqual(shown.orientation, .horizontal)
        guard case .split(let inner) = shown.second else {
            return XCTFail("2 and 3 share the right half")
        }
        XCTAssertEqual(inner.orientation, .vertical, "pinned to the shape it got")
        let hidden = try XCTUnwrap(plannedRoot([id(2): .floating, id(3): .floating]))
        guard case .split(let unseen) = hidden.second else {
            return XCTFail("the tree keeps the floating windows' leaves")
        }
        XCTAssertNil(unseen.orientation, "a split nothing showed stays free")
        XCTAssertNil(manager.currentWorkspace().dwindle.root.flatMap { root -> DwindleOrientation? in
            guard case .split(let split) = root else {
                return nil
            }
            return split.orientation
        }, "planning never writes the manager; the host stores the planned workspace")
    }

    func testADwindleDisplayShowsEveryTileAndParksNothing() throws {
        let manager = dwindleManager(3)
        var workspace = manager.currentWorkspace()
        workspace.viewportOffset = 300
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let planned = try planDisplayLayout(
            workspace: workspace, modes: [:],
            engine: ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10)),
            viewport: viewport, display: viewport, otherDisplays: [CGRect(x: 1000, y: 0, width: 800, height: 600)],
            centering: CenterRequest(mode: .always, previouslyFocused: id(1))
        )
        XCTAssertEqual(planned.plan.parked, [:])
        XCTAssertEqual(planned.plan.visible, try DwindleLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
            .layout(workspace.dwindle, viewport: viewport, modes: [:]).frames)
        XCTAssertEqual(planned.workspace.viewportOffset, 0, "no scrolling in dwindle")
        XCTAssertEqual(planned.layout.viewportOffset, 0)
    }

    func testPlanningAHandBuiltDwindleWorkspaceNeverDropsAWindow() throws {
        let workspace = Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 0, windows: ids(1, 2))],
            focusedWindow: id(1), layout: .dwindle
        )
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let planned = try planDisplayLayout(
            workspace: workspace, modes: [:], engine: ScrollableLayoutEngine(),
            viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(Set(planned.plan.visible.keys), Set(ids(1, 2)))
        XCTAssertEqual(planned.workspace.dwindle.windows, ids(1, 2))
    }

    func testAFocusedFullscreenWindowCoversTheDisplayAndTheOthersPark() throws {
        let manager = dwindleManager(3)
        let display = CGRect(x: 0, y: 0, width: 1000, height: 630)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let planned = try planDisplayLayout(
            workspace: manager.currentWorkspace(), modes: [id(3): .fullscreen],
            engine: ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10)),
            viewport: viewport, display: display, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible, [id(3): fullscreenFrame(display: display, usable: viewport, gap: 0)])
        XCTAssertEqual(Set(planned.plan.parked.keys), Set(ids(1, 2)))
    }

    func testAnUnfocusedFullscreenWindowKeepsItsTile() throws {
        var manager = dwindleManager(3)
        focus(&manager, 1)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let planned = try planDisplayLayout(
            workspace: manager.currentWorkspace(), modes: [id(3): .fullscreen],
            engine: ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10)),
            viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible[id(3)], CGRect(x: 505, y: 10, width: 485, height: 285))
        XCTAssertEqual(planned.plan.parked, [:])
    }

    func testAMaximizedFocusedWindowFillsTheAreaAndTheOthersStayInPlace() throws {
        var manager = dwindleManager(3)
        var workspace = manager.currentWorkspace()
        workspace.dwindle.maximized = id(3)
        manager.update(workspace)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 10, gap: 10))
        let planned = try planDisplayLayout(
            workspace: manager.currentWorkspace(), modes: [:], engine: engine,
            viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(planned.plan.visible[id(3)], CGRect(x: 10, y: 10, width: 980, height: 580))
        XCTAssertEqual(planned.plan.visible[id(1)], CGRect(x: 10, y: 10, width: 485, height: 580))
        XCTAssertEqual(planned.plan.parked, [:])

        focus(&manager, 1)
        XCTAssertNil(manager.currentWorkspace().dwindle.maximized, "focusing another window ends the zoom")
    }
}
