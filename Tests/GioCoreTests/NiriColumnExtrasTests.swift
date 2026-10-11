import XCTest
@testable import GioCore

/// NC-12: niri `focus-window-or-workspace-down/up`,
/// `switch-preset-column-width-back`, `expand-column-to-available-width`
/// and `center-visible-columns`.
final class NiriColumnExtrasTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))

    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    /// One single-window column per width (points), column `focused` focused.
    private func strip(_ widths: [CGFloat], focused: Int, offset: CGFloat = 0) -> Workspace {
        let columns = widths.enumerated().map { index, width in
            Column(id: ColumnID(UInt64(index + 1)), width: width, windows: [id(UInt64(index + 1))])
        }
        return Workspace(
            id: WorkspaceID(1), columns: columns, focusedColumn: focused,
            focusedWindow: id(UInt64(focused + 1)), viewportOffset: offset
        )
    }

    private func frames(_ workspace: Workspace) throws -> [WindowID: CGRect] {
        try engine.calculate(workspace: workspace, viewport: viewport).frames
    }

    // MARK: focus-window-or-workspace

    private func manager(stacked: Bool) -> WorkspaceManager {
        var manager = WorkspaceManager()
        var workspace = manager.currentWorkspace()
        workspace.columns = [Column(id: ColumnID(1), width: 300, windows: stacked ? [id(1), id(2)] : [id(1)])]
        workspace.focusedColumn = 0
        workspace.focusedWindow = id(1)
        manager.update(workspace)
        return manager
    }

    func testOrWorkspaceMovesWithinTheColumnFirst() {
        var stacked = manager(stacked: true)
        let start = stacked.current
        XCTAssertFalse(stacked.focusWindowOrWorkspaceDown(), "a window below: the workspace stays")
        XCTAssertEqual(stacked.current, start)
        XCTAssertEqual(stacked.currentWorkspace().focusedWindow, id(2))
        XCTAssertFalse(stacked.focusWindowOrWorkspaceUp())
        XCTAssertEqual(stacked.currentWorkspace().focusedWindow, id(1))
    }

    func testOrWorkspaceSwitchesWorkspaceAtTheColumnEnds() {
        var single = manager(stacked: false)
        let start = single.current
        XCTAssertFalse(single.focusWindowOrWorkspaceUp(), "the top workspace: nothing above")
        XCTAssertEqual(single.current, start)
        XCTAssertTrue(single.focusWindowOrWorkspaceDown(), "the last window: the workspace below")
        XCTAssertNotEqual(single.current, start)
        XCTAssertTrue(single.focusWindowOrWorkspaceUp(), "an empty workspace: straight up")
        XCTAssertEqual(single.current, start)
        XCTAssertEqual(single.currentWorkspace().focusedWindow, id(1))
    }

    func testOrWorkspaceAnimatesAsAWorkspaceSwitchAndTheColumnActionsAsTheirKind() {
        XCTAssertEqual(motionCause(for: .focusWindowOrWorkspaceDown).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .focusWindowOrWorkspaceUp).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .switchPresetColumnWidthBack).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .expandColumnToAvailableWidth).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .centerVisibleColumns).kind, .horizontalViewMovement)
        XCTAssertTrue(HotkeyAction.expandColumnToAvailableWidth.growsFocusedWindow)
        XCTAssertTrue(HotkeyAction.switchPresetColumnWidthBack.growsFocusedWindow)
        XCTAssertFalse(HotkeyAction.centerVisibleColumns.growsFocusedWindow)
    }

    // MARK: switch-preset-column-width-back

    func testPresetBackPicksTheWidestNarrowerPresetAndWraps() {
        let config = LayoutConfig(padding: 8, gap: 8)
        let presets = defaultPresetColumnWidths
        let half = strip([0], focused: 0)
        let third = switchPresetColumnWidthBack(in: half, presets: presets, config: config, viewportWidth: 1000)
        XCTAssertEqual(third.columns[0].widthSpec, .proportion(0.33333), "the default half goes back to a third")
        let wrapped = switchPresetColumnWidthBack(in: third, presets: presets, config: config, viewportWidth: 1000)
        XCTAssertEqual(wrapped.columns[0].widthSpec, .proportion(0.66667), "nothing narrower: the widest")
        XCTAssertEqual(switchPresetColumnWidthBack(in: half, presets: [], config: config, viewportWidth: 1000), half)
    }

    // MARK: expand-column-to-available-width

    func testExpandFillsWhatTheOtherFullyVisibleColumnsLeave() throws {
        // 600-wide columns at offset 0: 0 and 1 fully visible, 2 cut at 1800.
        let expanded = expandColumnToAvailableWidth(
            in: strip([600, 600, 600, 600], focused: 1), modes: [:], engine: engine, viewport: viewport
        )
        let laid = try frames(expanded)
        XCTAssertEqual(try XCTUnwrap(laid[id(2)]).width, 1784 - 600 - 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(laid[id(2)]).maxX, 1792, accuracy: 0.01, "ends at the right padding")
        XCTAssertEqual(try XCTUnwrap(laid[id(1)]).minX, 8, accuracy: 0.01, "the left neighbour stays in view")
    }

    func testExpandScrollsSoTheGroupFillsTheViewport() throws {
        // Offset 608: columns 1 and 2 (616...1824 in content) fully visible.
        let expanded = expandColumnToAvailableWidth(
            in: strip([600, 600, 600, 600, 600], focused: 2, offset: 608), modes: [:], engine: engine,
            viewport: viewport
        )
        XCTAssertEqual(expanded.viewportOffset, 608, accuracy: 0.01)
        let laid = try frames(expanded)
        XCTAssertEqual(try XCTUnwrap(laid[id(2)]).minX, 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(laid[id(3)]).maxX, 1792, accuracy: 0.01)
    }

    func testExpandWithoutRoomIsANoOp() {
        // Two 888 columns already fill the 1800 viewport.
        let full = strip([888, 888, 888], focused: 1)
        XCTAssertEqual(expandColumnToAvailableWidth(in: full, modes: [:], engine: engine, viewport: viewport), full)
    }

    func testExpandAloneTakesTheWholeStrip() throws {
        let expanded = expandColumnToAvailableWidth(
            in: strip([600], focused: 0), modes: [:], engine: engine, viewport: viewport
        )
        XCTAssertEqual(try XCTUnwrap(try frames(expanded)[id(1)]).width, 1784, accuracy: 0.01)
    }

    // MARK: center-visible-columns

    func testCenterVisibleCentersTheFullyVisibleGroup() throws {
        // 500-wide columns at offset 300: columns 1...3 (516...2032) fully visible.
        let workspace = strip([500, 500, 500, 500, 500], focused: 2, offset: 300)
        let centered = centerVisibleColumns(in: workspace, modes: [:], engine: engine, viewport: viewport)
        XCTAssertEqual(centered.viewportOffset, (516 + 2032) / 2 - 900, accuracy: 0.01)
        let planned = try planDisplayLayout(
            workspace: centered, modes: [:], engine: engine, viewport: viewport, display: viewport, otherDisplays: []
        )
        XCTAssertEqual(planned.workspace.viewportOffset, centered.viewportOffset, accuracy: 0.01, "the reveal keeps it")
    }

    func testCenterVisibleClampsAtTheStripStart() {
        let start = strip([500, 500, 500, 500, 500], focused: 1)
        XCTAssertEqual(centerVisibleColumns(in: start, modes: [:], engine: engine, viewport: viewport), start)
    }
}
