import XCTest
@testable import GioCore

/// DW-02: the dwindle actions as pure functions: geometric focus and moves
/// (with the workspace edge), split toggles, balance, preselection, sizes,
/// maximize, and the scrolling no-ops.
final class DwindleActionsTests: XCTestCase {
    /// 1000x600, padding and gaps 10. Spiral of four:
    /// 1 = (10,10,485,580) left half; 2 = (505,305,485,285) top right;
    /// 3 = (505,10,238,285) and 4 = (753,10,237,285) bottom right.
    private let geometry = DwindleGeometry(
        viewport: CGRect(x: 0, y: 0, width: 1000, height: 600),
        config: LayoutConfig(padding: 10, gap: 10)
    )

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 3, elementID: element)
    }

    private func ids(_ elements: UInt64...) -> [WindowID] {
        elements.map(id)
    }

    /// A dwindle workspace of `count` single-window columns, focus on `focus`.
    private func spiral(_ count: UInt64 = 4, focus: UInt64) -> Workspace {
        var workspace = Workspace(
            id: WorkspaceID(1),
            columns: (1...count).map { Column(id: ColumnID($0), width: 0, windows: [id($0)]) },
            focusedColumn: Int(focus) - 1, focusedWindow: id(focus), layout: .dwindle
        )
        workspace.reconcileDwindle(splitRatio: 1)
        return workspace
    }

    private func frames(_ workspace: Workspace) throws -> [WindowID: CGRect] {
        try DwindleLayoutEngine(config: geometry.config).layout(workspace.dwindle, viewport: geometry.viewport).frames
    }

    private func split(at path: DwindlePath, _ workspace: Workspace) -> DwindleSplit? {
        guard case .split(let split)? = workspace.dwindle.root?.node(at: path) else {
            return nil
        }
        return split
    }

    // MARK: - Focus

    func testFocusGoesToTheGeometricNeighbour() {
        let cases: [(from: UInt64, FocusDirection, to: UInt64?)] = [
            (1, .right, 2), (2, .left, 1), (2, .down, 3), (3, .up, 2), (3, .right, 4), (4, .left, 3),
            (4, .up, 2), (3, .left, 1), (1, .left, nil), (1, .up, nil), (1, .down, nil), (2, .up, nil),
            (4, .right, nil), (4, .down, nil),
        ]
        for (from, direction, to) in cases {
            let workspace = spiral(focus: from)
            let next = dwindleFocus(in: workspace, direction: direction, geometry: geometry)
            if let to {
                XCTAssertEqual(next.focusedWindow, id(to), "\(from) \(direction)")
                XCTAssertEqual(next.focusedColumnRef?.windows, [id(to)], "\(from) \(direction)")
                XCTAssertEqual(next.dwindle.selected, id(to), "\(from) \(direction)")
            } else {
                XCTAssertEqual(next, workspace, "\(from) \(direction): the edge leaves it unchanged")
            }
        }
    }

    func testAFocusedFloatingWindowNavigatesFromItsTile() {
        var floating = geometry
        floating.modes = [id(2): .floating]
        let next = dwindleFocus(in: spiral(focus: 2), direction: .left, geometry: floating)
        XCTAssertEqual(next.focusedWindow, id(1))
    }

    func testAPortraitDisplayChangesTheNeighbours() {
        let portrait = DwindleGeometry(
            viewport: CGRect(x: 0, y: 0, width: 600, height: 1000), config: LayoutConfig(padding: 10, gap: 10)
        )
        // Portrait: 1 on top, 2 below; nothing is to the right of 1.
        XCTAssertEqual(dwindleFocus(in: spiral(2, focus: 1), direction: .down, geometry: portrait).focusedWindow, id(2))
        XCTAssertEqual(dwindleFocus(in: spiral(2, focus: 1), direction: .right, geometry: portrait), spiral(2, focus: 1))
    }

    func testFocusFirstAndLastFollowLeafOrder() {
        XCTAssertEqual(dwindleFocusEnd(in: spiral(focus: 3), last: false).focusedWindow, id(1))
        XCTAssertEqual(dwindleFocusEnd(in: spiral(focus: 3), last: true).focusedWindow, id(4))
        XCTAssertEqual(dwindleFocusEnd(in: spiral(focus: 4), last: true), spiral(focus: 4))
    }

    // MARK: - Move

    func testMoveSwapsWithTheNeighbourAndKeepsTheFocus() throws {
        guard case .moved(let next) = dwindleMove(in: spiral(focus: 1), direction: .right, geometry: geometry) else {
            return XCTFail("1 has a neighbour on the right")
        }
        XCTAssertEqual(next.dwindle.windows, ids(2, 1, 3, 4))
        XCTAssertEqual(next.windows, ids(2, 1, 3, 4), "the columns follow the tree")
        XCTAssertEqual(next.focusedWindow, id(1))
        XCTAssertEqual(next.focusedColumnRef?.windows, ids(1))
        XCTAssertEqual(try frames(next)[id(1)], CGRect(x: 505, y: 305, width: 485, height: 285))
    }

    func testMoveAtTheEdgeReportsIt() {
        XCTAssertEqual(dwindleMove(in: spiral(focus: 4), direction: .right, geometry: geometry), .atEdge)
        XCTAssertEqual(dwindleMove(in: spiral(focus: 1), direction: .left, geometry: geometry), .atEdge)
        XCTAssertEqual(dwindleMove(in: spiral(1, focus: 1), direction: .down, geometry: geometry), .atEdge)
    }

    func testMoveWithoutFocusOrOnAScrollingWorkspaceIsUnchanged() {
        var unfocused = spiral(focus: 1)
        unfocused.focusedWindow = nil
        XCTAssertEqual(dwindleMove(in: unfocused, direction: .right, geometry: geometry), .unchanged)
        var scrolling = Workspace(id: WorkspaceID(1), columns: [Column(id: ColumnID(1), width: 0, windows: ids(1))])
        scrolling.focusedWindow = id(1)
        XCTAssertEqual(dwindleMove(in: scrolling, direction: .right, geometry: geometry), .unchanged)
    }

    // MARK: - Split commands

    func testToggleSplitFlipsTheFocusedWindowsSplitFromHowItIsLaidOut() throws {
        let next = dwindleToggleSplit(in: spiral(focus: 3), geometry: geometry)
        XCTAssertEqual(split(at: [.second, .second], next)?.orientation, .vertical, "side by side becomes stacked, pinned")
        XCTAssertEqual(try frames(next)[id(3)], CGRect(x: 505, y: 157, width: 485, height: 138))
        XCTAssertEqual(try frames(next)[id(4)], CGRect(x: 505, y: 10, width: 485, height: 137))
        let back = dwindleToggleSplit(in: next, geometry: geometry)
        XCTAssertEqual(split(at: [.second, .second], back)?.orientation, .horizontal)
        XCTAssertEqual(dwindleToggleSplit(in: spiral(1, focus: 1), geometry: geometry), spiral(1, focus: 1), "a lone window has no split")
    }

    func testSwapSplitTradesTheHalvesAndKeepsTheirSizes() throws {
        var workspace = spiral(focus: 1)
        workspace.dwindle.root = workspace.dwindle.root.map { root in
            guard case .split(var top) = root else {
                return root
            }
            top.ratio = 1.2
            return .split(top)
        }
        let next = dwindleSwapSplit(in: workspace)
        XCTAssertEqual(next.dwindle.windows, ids(2, 3, 4, 1))
        XCTAssertEqual(split(at: [], next)?.ratio ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(try frames(next)[id(1)]?.width, 582, "the window keeps its width on the other side")
        XCTAssertEqual(next.focusedWindow, id(1))
    }

    func testBalanceResetsEveryRatio() {
        var workspace = spiral(focus: 1)
        workspace.dwindle.root = workspace.dwindle.root?.mappingSplits { split in
            var skewed = split
            skewed.ratio = 1.5
            return skewed
        }
        let next = dwindleBalance(in: workspace)
        var ratios: [CGFloat] = []
        _ = next.dwindle.root?.mappingSplits { split in
            ratios.append(split.ratio)
            return split
        }
        XCTAssertEqual(ratios, [1, 1, 1])
        XCTAssertEqual(dwindleBalance(in: next), next, "already balanced: unchanged")
    }

    func testPreselectSetsAndClears() {
        let workspace = spiral(focus: 2)
        let left = dwindlePreselect(in: workspace, direction: .left)
        XCTAssertEqual(left.dwindle.preselection, .left)
        XCTAssertEqual(dwindlePreselect(in: left, direction: .left), left)
        XCTAssertNil(dwindlePreselect(in: left, direction: nil).dwindle.preselection)
        XCTAssertEqual(dwindlePreselect(in: workspace, direction: nil), workspace)
    }

    func testMaximizeTogglesTheFocusedWindow() {
        let workspace = spiral(focus: 2)
        let zoomed = dwindleToggleMaximize(in: workspace)
        XCTAssertEqual(zoomed.dwindle.maximized, id(2))
        XCTAssertNil(dwindleToggleMaximize(in: zoomed).dwindle.maximized)
    }

    // MARK: - Sizes

    func testWidthStepsMoveTheNearestSideBySideSplit() throws {
        let wider = dwindleResize(in: spiral(focus: 1), axis: .horizontal, by: 0.1, geometry: geometry)
        XCTAssertEqual(try frames(wider)[id(1)]?.width, 582)
        // Window 2 is on the right of the root split: its side grows.
        let right = dwindleResize(in: spiral(focus: 2), axis: .horizontal, by: 0.1, geometry: geometry)
        XCTAssertEqual(try frames(right)[id(1)]?.width, 388)
        XCTAssertEqual(try frames(right)[id(2)]?.width, 582)
        let narrower = dwindleResize(in: spiral(focus: 1), axis: .horizontal, by: -0.1, geometry: geometry)
        XCTAssertEqual(try frames(narrower)[id(1)]?.width, 388)
    }

    func testHeightStepsMoveTheNearestStackedSplitAndStopAtTheLimits() throws {
        let taller = dwindleResize(in: spiral(focus: 3), axis: .vertical, by: 0.1, geometry: geometry)
        XCTAssertEqual(try frames(taller)[id(3)]?.height, 342, "the bottom side gets 60% of 570")
        XCTAssertEqual(dwindleResize(in: spiral(focus: 1), axis: .vertical, by: 0.1, geometry: geometry), spiral(focus: 1),
                       "no stacked split above window 1")
        var clamped = spiral(focus: 1)
        for _ in 0..<20 {
            clamped = dwindleResize(in: clamped, axis: .horizontal, by: 0.1, geometry: geometry)
        }
        XCTAssertEqual(split(at: [], clamped)?.ratio, 1.9)
        XCTAssertEqual(dwindleResize(in: clamped, axis: .horizontal, by: 0.1, geometry: geometry), clamped)
    }

    func testPresetsCycleTheFocusedShareOfTheSplit() throws {
        let presets: [ColumnWidthSpec] = [.proportion(1.0 / 3), .proportion(0.5), .proportion(2.0 / 3)]
        let first = dwindleSwitchPreset(in: spiral(focus: 1), axis: .horizontal, presets: presets, forward: true, geometry: geometry)
        XCTAssertEqual(split(at: [], first)?.ratio ?? 0, 4.0 / 3, accuracy: 1e-9)
        let wrapped = dwindleSwitchPreset(in: first, axis: .horizontal, presets: presets, forward: true, geometry: geometry)
        XCTAssertEqual(split(at: [], wrapped)?.ratio ?? 0, 2.0 / 3, accuracy: 1e-9)
        let back = dwindleSwitchPreset(in: spiral(focus: 1), axis: .horizontal, presets: presets, forward: false, geometry: geometry)
        XCTAssertEqual(split(at: [], back)?.ratio ?? 0, 2.0 / 3, accuracy: 1e-9)
        // Points are measured against the split: 388 of 970 is 40%, on the right side.
        let points = dwindleSwitchPreset(
            in: spiral(focus: 2), axis: .horizontal, presets: [.points(388)], forward: true, geometry: geometry
        )
        XCTAssertEqual(try frames(points)[id(2)]?.width, 388)
    }

    func testResetSplitEvensTheNearestStackedSplit() throws {
        let taller = dwindleResize(in: spiral(focus: 3), axis: .vertical, by: 0.1, geometry: geometry)
        let reset = dwindleResetSplit(in: taller, axis: .vertical, geometry: geometry)
        XCTAssertEqual(split(at: [.second], reset)?.ratio, 1)
        XCTAssertEqual(try frames(reset), try frames(spiral(focus: 3)))
        XCTAssertEqual(dwindleResetSplit(in: reset, axis: .vertical, geometry: geometry), reset, "already even")
    }

    func testSizingPinsTheShapesSoInnerSplitsNeverFlip() throws {
        // Unpinned, 60% of the width would turn the right half (582x580)
        // side by side; resizing pins every split first.
        let wider = dwindleResize(in: spiral(focus: 2), axis: .horizontal, by: 0.1, geometry: geometry)
        XCTAssertEqual(split(at: [.second], wider)?.orientation, .vertical)
        XCTAssertEqual(split(at: [.second, .second], wider)?.orientation, .horizontal)
        XCTAssertEqual(try frames(wider)[id(2)], CGRect(x: 408, y: 305, width: 582, height: 285))
    }

    // MARK: - Scrolling workspaces

    func testDwindleActionsLeaveAScrollingWorkspaceAlone() {
        var workspace = Workspace(
            id: WorkspaceID(1),
            columns: [Column(id: ColumnID(1), width: 0, windows: ids(1)), Column(id: ColumnID(2), width: 0, windows: ids(2))],
            focusedWindow: id(1)
        )
        workspace.focusedColumn = 0
        XCTAssertEqual(dwindleFocus(in: workspace, direction: .right, geometry: geometry), workspace)
        XCTAssertEqual(dwindleToggleSplit(in: workspace, geometry: geometry), workspace)
        XCTAssertEqual(dwindleSwapSplit(in: workspace), workspace)
        XCTAssertEqual(dwindleBalance(in: workspace), workspace)
        XCTAssertEqual(dwindlePreselect(in: workspace, direction: .left), workspace)
        XCTAssertEqual(dwindleToggleMaximize(in: workspace), workspace)
        XCTAssertEqual(dwindleResize(in: workspace, axis: .horizontal, by: 0.1, geometry: geometry), workspace)
        XCTAssertEqual(dwindleFocusEnd(in: workspace, last: true), workspace)
        XCTAssertEqual(focusNeighbour(in: workspace, direction: .right, geometry: geometry), moveFocus(in: workspace, direction: .right))
    }

    // MARK: - Manager: Move Edge and focus-or-workspace

    private let left = DisplayID(11)
    private let right = DisplayID(12)
    private var displayFrames: [DisplayID: CGRect] {
        [left: CGRect(x: 0, y: 0, width: 1000, height: 600), right: CGRect(x: 1000, y: 0, width: 1000, height: 600)]
    }

    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 0, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    /// Left display: dwindle spiral 1...4, focus on `focus`; right display:
    /// a scrolling strip with 5 and 6.
    private func twoDisplays(focus: UInt64) -> WorkspaceManager {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        put(&manager, 5)
        put(&manager, 6)
        XCTAssertTrue(manager.focus(manager.activeID(on: left)!))
        XCTAssertTrue(manager.setLayout(.dwindle))
        for n in UInt64(1)...4 {
            put(&manager, n)
        }
        manager.update(adoptingFocus(id(focus), in: manager.currentWorkspace())!)
        return manager
    }

    func testMoveEdgeSwapsInsideTheTreeThenCrossesAtTheEdge() {
        var manager = twoDisplays(focus: 3)
        XCTAssertEqual(manager.moveColumnOrToDisplay(.right, frames: displayFrames, geometry: geometry), .withinWorkspace)
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows, ids(1, 2, 4, 3))
        XCTAssertEqual(manager.moveColumnOrToDisplay(.right, frames: displayFrames, geometry: geometry), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right)
        XCTAssertEqual(manager.currentWorkspace().windows, ids(3, 5, 6), "lands first, entering from the left edge")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        let leftTree = manager.workspace(id: manager.activeID(on: left)!)!.dwindle.windows
        XCTAssertEqual(leftTree, ids(1, 2, 4), "the source tree collapses")
    }

    func testMoveEdgeIntoADwindleTargetSplitsItsFocusedWindow() {
        var manager = twoDisplays(focus: 1)
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        XCTAssertTrue(manager.setLayout(.dwindle))
        // 5 is the right tree's left tile: nothing further left inside it.
        manager.update(adoptingFocus(id(5), in: manager.currentWorkspace())!)
        XCTAssertEqual(manager.moveColumnOrToDisplay(.left, frames: displayFrames, geometry: geometry), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, left)
        let tree = manager.currentWorkspace().dwindle.windows
        XCTAssertEqual(Set(tree), Set(ids(1, 2, 3, 4, 5)))
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5))
        XCTAssertEqual(manager.currentWorkspace().dwindle.root?.path(to: id(5)), [.first, .second], "5 split the focused window 1")
        XCTAssertEqual(manager.workspace(id: manager.activeID(on: right)!)?.dwindle.windows, ids(6))
    }

    func testMoveEdgeWithoutANeighbourDisplayChangesNothing() {
        var manager = twoDisplays(focus: 1)
        let before = manager
        XCTAssertEqual(manager.moveColumnOrToDisplay(.left, frames: displayFrames, geometry: geometry), .unchanged)
        XCTAssertEqual(manager, before)
    }

    func testFocusEdgeCrossesFromTheTreesEdge() {
        var manager = twoDisplays(focus: 2)
        XCTAssertEqual(manager.focusColumnOrDisplay(.left, frames: displayFrames, geometry: geometry), .withinWorkspace)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))
        var edge = twoDisplays(focus: 4)
        XCTAssertEqual(edge.focusColumnOrDisplay(.right, frames: displayFrames, geometry: geometry), .crossedDisplay)
        XCTAssertEqual(edge.focusedDisplay, right)
    }

    func testFocusWindowOrWorkspaceUsesTheTree() {
        var manager = twoDisplays(focus: 2)
        XCTAssertFalse(manager.focusWindowOrWorkspaceDown(geometry: geometry))
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        XCTAssertTrue(manager.focusWindowOrWorkspaceDown(geometry: geometry), "no tile below 3: the workspace below")
    }

    // MARK: - Action names, bindings, catalog

    func testTheActionsHaveKebabNamesAndTwoDefaultBindings() {
        let named: [(String, HotkeyAction)] = [
            ("toggle-workspace-layout", .toggleWorkspaceLayout),
            ("set-workspace-layout-scrolling", .setWorkspaceLayout(.scrolling)),
            ("set-workspace-layout-dwindle", .setWorkspaceLayout(.dwindle)),
            ("dwindle-toggle-split", .dwindleToggleSplit),
            ("dwindle-swap-split", .dwindleSwapSplit),
            ("dwindle-balance", .dwindleBalance),
            ("dwindle-preselect-left", .dwindlePreselect(.left)),
            ("dwindle-preselect-right", .dwindlePreselect(.right)),
            ("dwindle-preselect-up", .dwindlePreselect(.up)),
            ("dwindle-preselect-down", .dwindlePreselect(.down)),
            ("dwindle-preselect-clear", .dwindlePreselectClear),
        ]
        let catalog = shortcutCatalog(configKeybindings: [])
        for (name, action) in named {
            XCTAssertEqual(parseActionName(name), action, name)
            XCTAssertTrue(validActionNames().contains(name), name)
            XCTAssertEqual(configActionName(action), name)
            XCTAssertFalse(action.carriesFocusIntent, "\(name) keeps the focused window")
            XCTAssertFalse(action.growsFocusedWindow, name)
            XCTAssertEqual(catalog.first { $0.id == name }?.category, .layout, name)
        }
        let dispatcher = HotkeyDispatcher()
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "T")), .toggleWorkspaceLayout)
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "B")), .dwindleBalance)
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "Space")), .toggleFloating,
                       "Alt+Shift+Space stays toggle-floating")
        XCTAssertEqual(dispatcher.bindingCount, 77)
        XCTAssertEqual(motionCause(for: .toggleWorkspaceLayout), .windowMovement)
        XCTAssertEqual(motionCause(for: .setWorkspaceLayout(.dwindle)), .windowMovement)
        XCTAssertEqual(motionCause(for: .dwindleToggleSplit), .windowResize)
        XCTAssertEqual(motionCause(for: .dwindleSwapSplit), .windowMovement)
        XCTAssertEqual(motionCause(for: .dwindleBalance), .windowResize)
        XCTAssertEqual(motionCause(for: .dwindlePreselect(.left)), .passive)
        XCTAssertEqual(motionCause(for: .dwindlePreselectClear), .passive)
    }

    // MARK: - CLI

    func testGioFocusAndMoveFollowTheTree() {
        var manager = WorkspaceManager()
        XCTAssertTrue(manager.setLayout(.dwindle))
        for n in UInt64(1)...4 {
            put(&manager, n)
        }
        manager.update(adoptingFocus(id(3), in: manager.currentWorkspace())!)
        var session = CommandSession(manager: manager)
        var config = GioConfig()
        config.layout.gaps = 10
        config.layout.padding = 10
        session.config = config
        session.visibleFrames = [WorkspaceManager.placeholderDisplay: CGRect(x: 0, y: 0, width: 1000, height: 600)]
        XCTAssertEqual(dispatch(.focus(.up), session: &session), "focused column=1 window=3:2")
        XCTAssertEqual(dispatch(.move(.left), session: &session), "moved column=0")
        XCTAssertEqual(session.manager.currentWorkspace().dwindle.windows, ids(2, 1, 3, 4))
        XCTAssertEqual(dispatch(.move(.left), session: &session), "move unchanged (no target)")
    }
}
