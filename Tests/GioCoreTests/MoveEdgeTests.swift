import XCTest
@testable import GioCore

/// MM-06: niri `move-column-left/right-or-to-monitor-*` and
/// `focus-column-or-monitor-left/right`, the edge landing, and the
/// `[behavior] move-crosses-monitor-at-edge` toggle.
final class MoveEdgeTests: XCTestCase {
    private let left = DisplayID(11)
    private let right = DisplayID(12)
    private var frames: [DisplayID: CGRect] {
        [
            left: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            right: CGRect(x: 1800, y: 0, width: 1600, height: 1000),
        ]
    }

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func put(_ manager: inout WorkspaceManager, _ n: UInt64) {
        var workspace = manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(n), width: 300, windows: [id(n)]))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id(n)
        manager.update(workspace)
    }

    private func focusColumn(_ manager: inout WorkspaceManager, _ index: Int) {
        var workspace = manager.currentWorkspace()
        workspace.focusedColumn = index
        workspace.focusedWindow = workspace.columns[index].focusedWindowID
        manager.update(workspace)
    }

    private func layout(_ workspace: Workspace?) -> [[WindowID]] {
        workspace?.columns.map(\.windows) ?? []
    }

    /// Left display: columns 1, 2, 3 (focus on `focused`); right display:
    /// columns 4, 5, 6 (focus on its middle one).
    private func twoDisplays(focused: Int) -> WorkspaceManager {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        put(&manager, 4)
        put(&manager, 5)
        put(&manager, 6)
        focusColumn(&manager, 1)
        XCTAssertTrue(manager.focus(manager.activeID(on: left)!))
        put(&manager, 1)
        put(&manager, 2)
        put(&manager, 3)
        focusColumn(&manager, focused)
        return manager
    }

    // MARK: - Landing

    func testMoveColumnToDisplayLandingFirstLastOrAfterFocused() {
        let base = twoDisplays(focused: 2)
        var first = base
        XCTAssertTrue(first.moveColumn(toDisplay: right, landing: .first))
        XCTAssertEqual(layout(first.currentWorkspace()), [[id(3)], [id(4)], [id(5)], [id(6)]])
        XCTAssertEqual(first.currentWorkspace().focusedColumn, 0)
        XCTAssertEqual(first.currentWorkspace().focusedWindow, id(3))

        var last = base
        XCTAssertTrue(last.moveColumn(toDisplay: right, landing: .last))
        XCTAssertEqual(layout(last.currentWorkspace()), [[id(4)], [id(5)], [id(6)], [id(3)]])
        XCTAssertEqual(last.currentWorkspace().focusedColumn, 3)

        var after = base
        XCTAssertTrue(after.moveColumn(toDisplay: right))
        XCTAssertEqual(
            layout(after.currentWorkspace()), [[id(4)], [id(5)], [id(3)], [id(6)]],
            "move-column-to-monitor keeps landing after the focused column"
        )
    }

    // MARK: - move-column-*-or-to-monitor-*

    func testInsideTheStripTheColumnMovesAndTheDisplayStays() {
        for (start, direction, order) in [
            (1, FocusDirection.right, [id(1), id(3), id(2)]),
            (1, FocusDirection.left, [id(2), id(1), id(3)]),
        ] {
            var manager = twoDisplays(focused: start)
            XCTAssertEqual(manager.moveColumnOrToDisplay(direction, frames: frames), .withinWorkspace, "\(direction)")
            XCTAssertEqual(manager.focusedDisplay, left)
            XCTAssertEqual(manager.currentWorkspace().columns.flatMap(\.windows), order, "\(direction)")
            XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(2))
        }
    }

    func testMovingRightPastTheEdgeLandsFirstOnTheRightDisplayAndFocusFollows() {
        var manager = twoDisplays(focused: 2)
        let source = manager.currentID
        XCTAssertEqual(manager.moveColumnOrToDisplay(.right, frames: frames), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right, "focus follows the column")
        XCTAssertEqual(layout(manager.currentWorkspace()), [[id(3)], [id(4)], [id(5)], [id(6)]])
        XCTAssertEqual(manager.currentWorkspace().focusedColumn, 0, "it enters by the left edge")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        XCTAssertEqual(layout(manager.workspace(id: source)), [[id(1)], [id(2)]])
    }

    func testMovingLeftPastTheEdgeLandsLastOnTheLeftDisplay() {
        var manager = twoDisplays(focused: 0)
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))
        focusColumn(&manager, 0)
        XCTAssertEqual(manager.moveColumnOrToDisplay(.left, frames: frames), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, left)
        XCTAssertEqual(layout(manager.currentWorkspace()), [[id(1)], [id(2)], [id(3)], [id(4)]])
        XCTAssertEqual(manager.currentWorkspace().focusedColumn, 3, "it enters by the right edge")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(4))
    }

    func testAtTheEdgeWithoutADisplayThatWayNothingChanges() {
        var manager = twoDisplays(focused: 0)
        let before = manager
        XCTAssertEqual(manager.moveColumnOrToDisplay(.left, frames: frames), .unchanged)
        XCTAssertEqual(manager, before)
        var single = WorkspaceManager()
        single.syncDisplays([left])
        put(&single, 1)
        let alone = single
        XCTAssertEqual(single.moveColumnOrToDisplay(.right, frames: [left: frames[left]!]), .unchanged)
        XCTAssertEqual(single, alone)
        XCTAssertEqual(single.moveColumnOrToDisplay(.right, frames: [:]), .unchanged, "unknown geometry")
        XCTAssertEqual(single, alone)
    }

    func testAnEmptyWorkspaceAndVerticalDirectionsMoveNothing() {
        var manager = WorkspaceManager()
        manager.syncDisplays([left, right])
        let before = manager
        XCTAssertEqual(manager.moveColumnOrToDisplay(.right, frames: frames), .unchanged)
        XCTAssertEqual(manager, before)
        var filled = twoDisplays(focused: 2)
        let start = filled
        XCTAssertEqual(filled.moveColumnOrToDisplay(.up, frames: frames), .unchanged)
        XCTAssertEqual(filled.moveColumnOrToDisplay(.down, frames: frames), .unchanged)
        XCTAssertEqual(filled, start)
    }

    // MARK: - focus-column-or-monitor-*

    func testFocusInsideTheStripThenTheNeighbourDisplayAtTheEdge() {
        var manager = twoDisplays(focused: 1)
        XCTAssertEqual(manager.focusColumnOrDisplay(.right, frames: frames), .withinWorkspace)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
        XCTAssertEqual(manager.focusedDisplay, left)

        XCTAssertEqual(manager.focusColumnOrDisplay(.right, frames: frames), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5), "the display's own focused column")

        XCTAssertEqual(manager.focusColumnOrDisplay(.left, frames: frames), .withinWorkspace)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(4))
        XCTAssertEqual(manager.focusColumnOrDisplay(.left, frames: frames), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, left)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(3))
    }

    func testFocusAtTheEdgeWithoutANeighbourChangesNothing() {
        var manager = twoDisplays(focused: 0)
        let before = manager
        XCTAssertEqual(manager.focusColumnOrDisplay(.left, frames: frames), .unchanged)
        XCTAssertEqual(manager.focusColumnOrDisplay(.up, frames: frames), .unchanged)
        XCTAssertEqual(manager, before)
    }

    func testAFloatingColumnAtTheEdgeDoesNotBlockCrossingDisplays() {
        var manager = twoDisplays(focused: 2)
        put(&manager, 7)
        focusColumn(&manager, 2)
        let floating = DwindleGeometry(viewport: frames[left]!, modes: [id(7): .floating])
        XCTAssertEqual(manager.focusColumnOrDisplay(.right, frames: frames, geometry: floating), .crossedDisplay)
        XCTAssertEqual(manager.focusedDisplay, right)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id(5))
    }

    // MARK: - Reveal

    func testTheTargetViewportRevealsTheLandedColumn() throws {
        let engine = ScrollableLayoutEngine(config: LayoutConfig(maximizeSingleWindow: false))
        for (direction, start) in [(FocusDirection.right, 2), (FocusDirection.left, 0)] {
            var manager = WorkspaceManager()
            manager.syncDisplays([left, right])
            let source = direction == .right ? left : right
            let target = direction == .right ? right : left
            XCTAssertTrue(manager.focus(manager.activeID(on: target)!))
            for n in UInt64(10)...UInt64(17) {
                put(&manager, n)
            }
            // Scrolled to the far end from where the column will enter.
            focusColumn(&manager, direction == .right ? 7 : 0)
            var scrolled = manager.currentWorkspace()
            scrolled.viewportOffset = direction == .right ? 1_000 : 0
            manager.update(scrolled)
            XCTAssertTrue(manager.focus(manager.activeID(on: source)!))
            put(&manager, 1)
            put(&manager, 2)
            put(&manager, 3)
            focusColumn(&manager, start)
            let moving = manager.currentWorkspace().focusedWindow!
            XCTAssertEqual(manager.moveColumnOrToDisplay(direction, frames: frames), .crossedDisplay)
            let shown = frames[target]!
            let plan = try planDisplayLayout(
                workspace: manager.currentWorkspace(), modes: [:], engine: engine,
                viewport: shown, display: shown, otherDisplays: []
            )
            let frame = try XCTUnwrap(plan.plan.visible[moving], "\(direction): the landed column is visible")
            XCTAssertGreaterThanOrEqual(frame.minX, shown.minX - 0.5, "\(direction)")
            XCTAssertLessThanOrEqual(frame.maxX, shown.maxX + 0.5, "\(direction)")
        }
    }

    // MARK: - Config

    func testTheToggleIsOffByDefaultParsesAndRejectsANonBoolean() throws {
        XCTAssertFalse(GioConfig().behavior.moveCrossesMonitorAtEdge)
        let (on, warnings) = try parseGioConfig("[behavior]\nmove-crosses-monitor-at-edge = true\n").get()
        XCTAssertTrue(on.behavior.moveCrossesMonitorAtEdge)
        XCTAssertTrue(warnings.isEmpty)
        guard case .failure(let error) = parseGioConfig("[behavior]\nmove-crosses-monitor-at-edge = \"yes\"\n") else {
            return XCTFail("a non-boolean must be rejected")
        }
        XCTAssertEqual(error.messages, ["line 2: behavior.move-crosses-monitor-at-edge expects true or false"])
        let (template, templateWarnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertEqual(templateWarnings, [])
        XCTAssertFalse(template.behavior.moveCrossesMonitorAtEdge)
    }

    func testTheBehaviorEditPatchesTheKeyAndKeepsComments() throws {
        let edits = behaviorEdits(focusFollowsMouse: false, mouseFollowsFocus: true, moveCrossesMonitorAtEdge: true)
        XCTAssertTrue(edits.contains(.set(table: "behavior", key: "move-crosses-monitor-at-edge", value: .bool(true))))
        let original = "# mine\n[behavior]\n# keep me\nfocus-follows-mouse = false\n"
        guard case .success(let patched) = patchGioConfig(original, edits: edits) else {
            return XCTFail("the edits must patch")
        }
        XCTAssertTrue(patched.config.behavior.moveCrossesMonitorAtEdge)
        XCTAssertTrue(patched.text.contains("# mine"))
        XCTAssertTrue(patched.text.contains("# keep me"))
        XCTAssertTrue(patched.text.contains("move-crosses-monitor-at-edge = true"))
    }

    // MARK: - Actions

    func testTheFourActionsHaveNiriNamesShipUnboundAndCarryFocus() {
        let named: [(String, HotkeyAction)] = [
            ("move-column-left-or-to-monitor-left", .moveColumnLeftOrToMonitorLeft),
            ("move-column-right-or-to-monitor-right", .moveColumnRightOrToMonitorRight),
            ("focus-column-or-monitor-left", .focusColumnOrMonitorLeft),
            ("focus-column-or-monitor-right", .focusColumnOrMonitorRight),
        ]
        let bound = defaultHotkeyBindings().map(\.1)
        for (name, action) in named {
            XCTAssertEqual(parseActionName(name), action, name)
            XCTAssertTrue(validActionNames().contains(name), name)
            XCTAssertEqual(configActionName(action), name)
            XCTAssertFalse(bound.contains(action), "\(name) ships unbound")
            XCTAssertTrue(action.carriesFocusIntent, name)
        }
        XCTAssertEqual(motionCause(for: .moveColumnLeftOrToMonitorLeft), .windowMovement)
        XCTAssertEqual(motionCause(for: .moveColumnRightOrToMonitorRight), .windowMovement)
        XCTAssertEqual(motionCause(for: .focusColumnOrMonitorLeft), .viewScroll)
        XCTAssertEqual(motionCause(for: .focusColumnOrMonitorRight), .viewScroll)
        XCTAssertEqual(HotkeyDispatcher().bindingCount, 79, "NC-14 added two")
    }
}
