import XCTest
@testable import GioCore

/// NC-14: the OmniWM-style window move (`moveWindowOrToDisplay`), behind
/// `consume-or-expel-window-left/right` and `move-up/down`. Inside the
/// workspace a stacked window is expelled and a lone one consumed (left and
/// right) or it trades places in its column (up and down); from the
/// workspace's edge it crosses to the neighbouring display only with
/// `crossesAtEdge` (Move Edge), stacking at the bottom of the target column
/// nearest the edge it enters by.
final class WindowMoveEdgeTests: XCTestCase {
    private let left = DisplayID(11)
    private let right = DisplayID(12)
    private let top = DisplayID(13)
    private var sideBySide: [DisplayID: CGRect] {
        [
            left: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            right: CGRect(x: 1800, y: 0, width: 1600, height: 1000),
        ]
    }

    /// `left` below `top` (up = higher Cocoa y).
    private var stacked: [DisplayID: CGRect] {
        [
            left: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            top: CGRect(x: 0, y: 1169, width: 1800, height: 1000),
        ]
    }

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func layout(_ workspace: Workspace?) -> [[UInt64]] {
        workspace?.columns.map { $0.windows.map(\.elementID) } ?? []
    }

    /// Fill the current workspace with `columns` (window numbers top to
    /// bottom) and focus window `focus`.
    private func fill(_ manager: inout WorkspaceManager, _ columns: [[UInt64]], focus: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns = columns.enumerated().map { index, windows in
            Column(id: ColumnID(UInt64(index + 1) + windows[0] * 100), width: 300, windows: windows.map(id))
        }
        manager.update(adoptingFocus(id(focus), in: workspace)!)
    }

    /// `source` shows `columns` with `focus`; `other` shows `otherColumns`
    /// (its focus on `otherFocus`, or nothing when empty).
    private func manager(
        _ ids: [DisplayID], source: DisplayID, _ columns: [[UInt64]], focus: UInt64,
        other: DisplayID? = nil, _ otherColumns: [[UInt64]] = [], otherFocus: UInt64? = nil
    ) -> WorkspaceManager {
        var manager = WorkspaceManager()
        manager.syncDisplays(ids)
        if let other, !otherColumns.isEmpty {
            XCTAssertTrue(manager.focus(manager.activeID(on: other)!))
            fill(&manager, otherColumns, focus: otherFocus ?? otherColumns[0][0])
        }
        if manager.focusedDisplay != source {
            XCTAssertTrue(manager.focus(manager.activeID(on: source)!))
        }
        fill(&manager, columns, focus: focus)
        return manager
    }

    // MARK: - Inside the workspace (left / right)

    func testAStackedWindowIsExpelledIntoItsOwnColumnOnThatSide() {
        for (direction, expected, column) in [
            (FocusDirection.left, [[1], [3], [2], [4]] as [[UInt64]], 1),
            (FocusDirection.right, [[1], [2], [3], [4]] as [[UInt64]], 2),
        ] {
            for crosses in [false, true] {
                var manager = manager([left, right], source: left, [[1], [2, 3], [4]], focus: 3)
                XCTAssertEqual(
                    manager.moveWindowOrToDisplay(direction, frames: sideBySide, crossesAtEdge: crosses),
                    .withinWorkspace, "\(direction)"
                )
                XCTAssertEqual(layout(manager.currentWorkspace()), expected, "\(direction)")
                XCTAssertEqual(manager.currentWorkspace().focusedColumn, column, "\(direction)")
                XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3), "\(direction): focus follows")
                XCTAssertEqual(manager.focusedDisplay, left)
            }
        }
    }

    func testAStackedWindowInTheEdgeColumnStillExpelsInsideTheWorkspace() {
        var manager = manager([left, right], source: left, [[1], [2, 3]], focus: 3)
        XCTAssertEqual(manager.moveWindowOrToDisplay(.right, frames: sideBySide, crossesAtEdge: true), .withinWorkspace)
        XCTAssertEqual(layout(manager.currentWorkspace()), [[1], [2], [3]])
        XCTAssertEqual(manager.focusedDisplay, left, "a new last column, not the other display")
    }

    func testALoneWindowIsConsumedAtTheBottomOfTheNeighbourColumnAndStaysActive() {
        for (direction, expected) in [
            (FocusDirection.left, [[1, 2, 3], [4]] as [[UInt64]]),
            (FocusDirection.right, [[1, 2], [4, 3]] as [[UInt64]]),
        ] {
            var manager = manager([left, right], source: left, [[1, 2], [3], [4]], focus: 3)
            XCTAssertEqual(
                manager.moveWindowOrToDisplay(direction, frames: sideBySide, crossesAtEdge: true),
                .withinWorkspace, "\(direction)"
            )
            let workspace = manager.currentWorkspace()
            XCTAssertEqual(layout(workspace), expected, "\(direction)")
            XCTAssertEqual(workspace.focusedWindow, id(3), "\(direction)")
            XCTAssertEqual(workspace.columns[workspace.focusedColumn].focusedWindowID, id(3), "\(direction)")
        }
    }

    // MARK: - The workspace's edge (left / right)

    func testAtTheEdgeWithMoveEdgeOffNothingChanges() {
        for (direction, focus) in [(FocusDirection.left, UInt64(1)), (.right, 3)] {
            var manager = manager([left, right], source: left, [[1], [2], [3]], focus: focus)
            let before = manager
            XCTAssertEqual(
                manager.moveWindowOrToDisplay(direction, frames: sideBySide, crossesAtEdge: false), .unchanged
            )
            XCTAssertEqual(manager, before, "\(direction)")
        }
    }

    func testAloneInTheOnlyColumnWithoutANeighbourNothingChanges() {
        for direction in [FocusDirection.left, .right, .up, .down] {
            for crosses in [false, true] {
                var manager = manager([left], source: left, [[1]], focus: 1)
                let before = manager
                XCTAssertEqual(
                    manager.moveWindowOrToDisplay(direction, frames: [left: sideBySide[left]!], crossesAtEdge: crosses),
                    .unchanged, "\(direction) \(crosses)"
                )
                XCTAssertEqual(manager, before, "one display: Move Edge has nowhere to go")
            }
        }
    }

    func testMovingRightFromTheLastColumnStacksIntoTheTargetsFirstColumn() {
        var manager = manager(
            [left, right], source: left, [[1], [2]], focus: 2,
            other: right, [[5, 6], [7]], otherFocus: 7
        )
        let source = manager.currentID
        XCTAssertEqual(manager.moveWindowOrToDisplay(.right, frames: sideBySide, crossesAtEdge: true), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right, "focus follows the window")
        let target = manager.currentWorkspace()
        XCTAssertEqual(layout(target), [[5, 6, 2], [7]], "the column nearest the left edge, at its bottom")
        XCTAssertEqual(target.focusedColumn, 0)
        XCTAssertEqual(target.focusedWindow, id(2))
        XCTAssertEqual(target.columns[0].focusedWindowID, id(2))
        XCTAssertEqual(layout(manager.workspace(id: source)), [[1]], "the emptied column is gone")
    }

    func testMovingLeftFromTheFirstColumnStacksIntoTheTargetsLastColumn() {
        var manager = manager(
            [left, right], source: right, [[5], [6]], focus: 5,
            other: left, [[1], [2, 3]], otherFocus: 1
        )
        XCTAssertEqual(manager.moveWindowOrToDisplay(.left, frames: sideBySide, crossesAtEdge: true), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, left)
        let target = manager.currentWorkspace()
        XCTAssertEqual(layout(target), [[1], [2, 3, 5]], "the column nearest the right edge, at its bottom")
        XCTAssertEqual(target.focusedColumn, 1)
        XCTAssertEqual(target.focusedWindow, id(5))
    }

    func testCrossingIntoAnEmptyWorkspaceMakesTheWindowItsOwnColumn() {
        var manager = manager([left, right], source: left, [[1], [2]], focus: 2)
        XCTAssertEqual(manager.moveWindowOrToDisplay(.right, frames: sideBySide, crossesAtEdge: true), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right)
        XCTAssertEqual(layout(manager.currentWorkspace()), [[2]])
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(2))
    }

    func testAtTheEdgeWithoutADisplayThatWayNothingChanges() {
        var manager = manager([left, right], source: left, [[1], [2]], focus: 1)
        let before = manager
        XCTAssertEqual(manager.moveWindowOrToDisplay(.left, frames: sideBySide, crossesAtEdge: true), .unchanged)
        XCTAssertEqual(manager, before)
        XCTAssertEqual(manager.moveWindowOrToDisplay(.left, frames: [:], crossesAtEdge: true), .unchanged, "unknown geometry")
        XCTAssertEqual(manager, before)
    }

    // MARK: - Up / down

    func testUpAndDownTradePlacesInsideTheColumn() {
        for (direction, expected) in [
            (FocusDirection.up, [[2, 1, 3]] as [[UInt64]]), (FocusDirection.down, [[1, 3, 2]] as [[UInt64]]),
        ] {
            var manager = manager([left, top], source: left, [[1, 2, 3]], focus: 2)
            XCTAssertEqual(
                manager.moveWindowOrToDisplay(direction, frames: stacked, crossesAtEdge: true), .withinWorkspace
            )
            XCTAssertEqual(layout(manager.currentWorkspace()), expected, "\(direction)")
            XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(2))
            XCTAssertEqual(manager.focusedDisplay, left)
        }
    }

    func testAtTheColumnsTopMoveEdgeCrossesToTheDisplayAbove() {
        var off = manager([left, top], source: left, [[1, 2], [3]], focus: 1, other: top, [[5], [6]], otherFocus: 6)
        let before = off
        XCTAssertEqual(off.moveWindowOrToDisplay(.up, frames: stacked, crossesAtEdge: false), .unchanged)
        XCTAssertEqual(off, before, "off: the column's top stops it")

        var on = before
        XCTAssertEqual(on.moveWindowOrToDisplay(.up, frames: stacked, crossesAtEdge: true), .crossedDisplay)
        XCTAssertEqual(on.focusedDisplay, top)
        XCTAssertEqual(layout(on.currentWorkspace()), [[5], [6, 1]], "the target's focused column, at its bottom")
        XCTAssertEqual(on.currentWorkspace().focusedWindow, id(1))
        XCTAssertEqual(layout(on.workspace(id: before.currentID)), [[2], [3]])
    }

    func testAtTheColumnsBottomMoveEdgeCrossesToTheDisplayBelow() {
        var manager = manager([left, top], source: top, [[5, 6]], focus: 6, other: left, [[1], [2]], otherFocus: 1)
        XCTAssertEqual(manager.moveWindowOrToDisplay(.down, frames: stacked, crossesAtEdge: true), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, left)
        XCTAssertEqual(layout(manager.currentWorkspace()), [[1, 6], [2]])
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(6))
        var edge = manager
        let before = edge
        XCTAssertEqual(edge.moveWindowOrToDisplay(.down, frames: stacked, crossesAtEdge: true), .unchanged, "nothing below")
        XCTAssertEqual(edge, before)
    }

    // MARK: - Nothing to move

    func testAnEmptyWorkspaceMovesNothing() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        let before = manager
        for direction in [FocusDirection.left, .right, .up, .down] {
            XCTAssertEqual(manager.moveWindowOrToDisplay(direction, frames: sideBySide, crossesAtEdge: true), .unchanged)
            XCTAssertEqual(manager, before)
        }
    }

    // MARK: - Dwindle

    private let dwindleFrames: [DisplayID: CGRect] = [
        DisplayID(11): CGRect(x: 0, y: 0, width: 1000, height: 600),
        DisplayID(12): CGRect(x: 1000, y: 0, width: 1000, height: 600),
    ]

    private var geometry: DwindleGeometry {
        DwindleGeometry(viewport: dwindleFrames[left]!, config: LayoutConfig(padding: 10, gap: 10))
    }

    /// Left display: a dwindle spiral 1...3 (1 left half, 2 top right, 3
    /// bottom right), focus on `focus`; right display: `rightColumns`.
    private func dwindle(focus: UInt64, rightColumns: [[UInt64]] = [[5, 6], [7]]) -> WorkspaceManager {
        var manager = manager([left, right], source: right, rightColumns, focus: rightColumns[0][0])
        XCTAssertTrue(manager.focus(manager.activeID(on: left)!))
        XCTAssertTrue(manager.setLayout(.dwindle))
        fill(&manager, [[1], [2], [3]], focus: focus)
        return manager
    }

    func testDwindleSwapsWithTheGeometricNeighbourThenCrossesAtTheEdge() {
        var manager = dwindle(focus: 1)
        XCTAssertEqual(
            manager.moveWindowOrToDisplay(.right, frames: dwindleFrames, crossesAtEdge: true, geometry: geometry),
            .withinWorkspace
        )
        XCTAssertEqual(manager.currentWorkspace().dwindle.windows.map(\.elementID), [2, 1, 3], "a swap, as dwindleMove")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(1))

        var edge = dwindle(focus: 2)
        let before = edge
        XCTAssertEqual(
            edge.moveWindowOrToDisplay(.right, frames: dwindleFrames, crossesAtEdge: false, geometry: geometry),
            .unchanged
        )
        XCTAssertEqual(edge, before, "off: the tree's edge stops it")
        XCTAssertEqual(
            edge.moveWindowOrToDisplay(.right, frames: dwindleFrames, crossesAtEdge: true, geometry: geometry),
            .crossedDisplay
        )
        XCTAssertEqual(edge.focusedDisplay, right)
        XCTAssertEqual(layout(edge.currentWorkspace()), [[5, 6, 2], [7]], "a scrolling target stacks it")
        XCTAssertEqual(edge.workspace(id: before.currentID)?.dwindle.windows.map(\.elementID), [1, 3])
    }

    func testCrossingIntoADwindleTargetAddsItAsATile() {
        var manager = manager([left, right], source: right, [[5], [6]], focus: 5)
        XCTAssertTrue(manager.setLayout(.dwindle))
        XCTAssertTrue(manager.focus(manager.activeID(on: left)!))
        fill(&manager, [[1], [2]], focus: 2)
        XCTAssertEqual(manager.moveWindowOrToDisplay(.right, frames: dwindleFrames, crossesAtEdge: true), .crossedDisplay)
        let target = manager.currentWorkspace()
        XCTAssertEqual(target.layout, .dwindle)
        XCTAssertEqual(layout(target), [[5], [2], [6]], "its own tile, splitting the focused 5: one window per dwindle column")
        XCTAssertEqual(Set(target.dwindle.windows), Set([id(2), id(5), id(6)]))
        XCTAssertEqual(target.focusedWindow, id(2))
    }

    // MARK: - CLI

    func testGioMoveIsTheWindowMoveAndCrossesOnlyWithTheToggle() {
        var session = CommandSession(manager: manager([left, right], source: left, [[1], [2, 3]], focus: 3))
        session.displayFrames = sideBySide
        XCTAssertEqual(dispatch(.move(.right), session: &session), "moved column=2")
        XCTAssertEqual(layout(session.manager.currentWorkspace()), [[1], [2], [3]], "expelled")
        let before = session.manager
        XCTAssertEqual(dispatch(.move(.right), session: &session), "move unchanged (no target)")
        XCTAssertEqual(session.manager, before, "off: the edge stops the window")

        var config = GioConfig()
        config.behavior.moveCrossesMonitorAtEdge = true
        session.config = config
        XCTAssertEqual(dispatch(.move(.right), session: &session), "moved window to the display on the right")
        XCTAssertEqual(session.manager.focusedDisplay, right)
        XCTAssertEqual(dispatch(.move(.up), session: &session), "move unchanged (no target)")
        XCTAssertEqual(dispatch(.move(.left), session: &session), "moved window to the display on the left")
        XCTAssertEqual(layout(session.manager.currentWorkspace()), [[1], [2, 3]], "consumed into the last column")
    }

    // MARK: - Bindings and names

    func testAltShiftHLMoveTheWindowAndCommaPeriodMoveTheColumn() {
        let dispatcher = HotkeyDispatcher()
        func action(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyAction? {
            dispatcher.action(for: HotkeyCombo(modifiers: modifiers, key: key))
        }
        XCTAssertEqual(action([.alt, .shift], "H"), .consumeOrExpelLeft)
        XCTAssertEqual(action([.alt, .shift], "L"), .consumeOrExpelRight)
        XCTAssertEqual(action([.alt, .shift], "K"), .moveUp)
        XCTAssertEqual(action([.alt, .shift], "J"), .moveDown)
        XCTAssertEqual(action([.alt], "BracketLeft"), .consumeOrExpelLeft, "niri's Mod+[ stays")
        XCTAssertEqual(action([.alt], "BracketRight"), .consumeOrExpelRight)
        XCTAssertEqual(action([.alt, .shift], "Comma"), .moveColumnLeft, "`<`")
        XCTAssertEqual(action([.alt, .shift], "Period"), .moveColumnRight, "`>`")
        XCTAssertNil(action([.alt, .shift], "Left"), "Option+Shift+arrows stay word selection")
        XCTAssertNil(action([.alt, .shift], "Right"))
        XCTAssertEqual(dispatcher.bindingCount, 79, "NC-14 added the column move's two combos")
        for (name, value) in [
            ("consume-or-expel-window-left", HotkeyAction.consumeOrExpelLeft),
            ("consume-or-expel-window-right", .consumeOrExpelRight),
            ("move-up", .moveUp), ("move-down", .moveDown),
            ("move-column-left", .moveColumnLeft), ("move-column-right", .moveColumnRight),
        ] {
            XCTAssertEqual(parseActionName(name), value, name)
            XCTAssertEqual(configActionName(value), name)
            XCTAssertTrue(validActionNames().contains(name), name)
            XCTAssertTrue(value.carriesFocusIntent, "\(name): focus follows the window")
        }
    }

    func testTheUsersSwapOverridesOnAltShiftBracketsStillParse() throws {
        let text = """
        [keybindings]
        "Alt+Shift+BracketLeft" = "swap-window-left"
        "Alt+Shift+BracketRight" = "swap-window-right"
        """
        let (config, warnings) = try parseGioConfig(text).get()
        XCTAssertEqual(warnings, [])
        let dispatcher = config.makeDispatcher()
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "BracketLeft")), .swapWindowLeft
        )
        XCTAssertEqual(
            dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "BracketRight")), .swapWindowRight
        )
        XCTAssertEqual(dispatcher.action(for: HotkeyCombo(modifiers: [.alt, .shift], key: "H")), .consumeOrExpelLeft)
    }
}
