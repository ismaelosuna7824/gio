import CoreGraphics
import XCTest
@testable import GioCore

/// TG-03: the strip under a scroll gesture: the fingers' travel mapped to
/// the viewport offset, the frames of each step (columns entering the
/// viewport un-park as they arrive), the niri snap on release (projection,
/// column edges, strip ends, the furthest visible column in the swipe's
/// direction), the State commit and the velocity handed to the spring.
final class StripGestureTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))

    private func id(_ n: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: n)
    }

    /// Columns of 600 pt: content x 8-608, 616-1216, 1224-1824, 1832-2432;
    /// content width 2440, so the offset runs 0...1440.
    private func workspace(columns: Int = 4, width: CGFloat = 600, focused: Int = 0, offset: CGFloat = 0) -> Workspace {
        Workspace(
            id: WorkspaceID(1),
            columns: (1...columns).map { Column(id: ColumnID(UInt64($0)), width: width, windows: [id(UInt64($0))]) },
            focusedColumn: focused, focusedWindow: id(UInt64(focused + 1)), viewportOffset: offset
        )
    }

    private func surface(_ workspace: Workspace, modes: [WindowID: WindowMode] = [:], centering: Bool = false) -> GestureSurface {
        GestureSurface(
            display: DisplayID(1), workspace: workspace, modes: modes, engine: engine,
            viewport: viewport, displayFrame: viewport, otherDisplays: [], centering: centering
        )
    }

    // MARK: - Strip

    func testStripListsTheTiledColumnsInContentSpace() throws {
        let strip = try XCTUnwrap(gestureStrip(surface(workspace(offset: 300))))
        XCTAssertEqual(strip.columns.map(\.start), [8, 616, 1224, 1832])
        XCTAssertEqual(strip.columns.map(\.end), [608, 1216, 1824, 2432])
        XCTAssertEqual(strip.columns.map(\.focus), [id(1), id(2), id(3), id(4)])
        XCTAssertEqual(strip.maxOffset, 1440)
        XCTAssertEqual(strip.committedOffset, 300)
    }

    func testStripFocusesEachColumnsFocusedWindowAndSkipsFloatingOnes() throws {
        var ws = workspace(columns: 2)
        ws.columns[1].windows = [id(2), id(7)]
        ws.columns[1].focusedWindowIndex = 1
        let strip = try XCTUnwrap(gestureStrip(surface(ws)))
        XCTAssertEqual(strip.columns.map(\.focus), [id(1), id(7)])
        let floating = try XCTUnwrap(gestureStrip(surface(ws, modes: [id(7): .floating])))
        XCTAssertEqual(floating.columns.map(\.focus), [id(1), id(2)])
    }

    func testNoStripWithoutColumnsOrWithAFullscreenWindow() {
        XCTAssertNil(gestureStrip(surface(Workspace(id: WorkspaceID(1)))))
        XCTAssertNil(gestureStrip(surface(workspace(), modes: [id(2): .fullscreen])))
    }

    /// DW: a dwindle workspace has no strip to scroll; its windows stay put.
    func testNoStripOnADwindleWorkspace() {
        var dwindle = workspace()
        dwindle.layout = .dwindle
        XCTAssertNil(gestureStrip(surface(dwindle)))
    }

    func testFingerTravelMapsToTheOffset() {
        XCTAssertEqual(gestureOffsetDelta(fingerDX: -0.1, viewportWidth: 1000, sensitivity: 1, natural: true), 100)
        XCTAssertEqual(gestureOffsetDelta(fingerDX: -0.1, viewportWidth: 1000, sensitivity: 2, natural: false), -200)
    }

    func testTrackerClampsAtTheStripEndsAndReversesAtOnce() {
        var tracker = GestureScrollTracker(base: 100, maxOffset: 1440)
        tracker.apply(-300)
        XCTAssertEqual(tracker.offset, 0)
        tracker.apply(50)
        XCTAssertEqual(tracker.offset, 50, "no dead zone after pushing past the start")
        tracker.apply(5000)
        XCTAssertEqual(tracker.offset, 1440)
    }

    func testTheGestureMovesTheStripUnderThePointerElseTheFocusedOne() {
        let viewport = Viewport(width: 1000)
        let left = DisplayState(
            id: DisplayID(1), frame: CGRect(x: 0, y: 0, width: 1000, height: 800), workspace: WorkspaceID(1), viewport: viewport
        )
        let right = DisplayState(
            id: DisplayID(2), frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), workspace: WorkspaceID(2), viewport: viewport
        )
        XCTAssertEqual(gestureDisplay(at: CGPoint(x: 1500, y: 400), displays: [left, right], focused: DisplayID(1))?.id, DisplayID(2))
        XCTAssertEqual(gestureDisplay(at: CGPoint(x: -50, y: 400), displays: [left, right], focused: DisplayID(2))?.id, DisplayID(2))
        XCTAssertNil(gestureDisplay(at: .zero, displays: [], focused: DisplayID(1)))
    }

    func testFramesFollowTheOffsetAndColumnsUnparkAsTheyArrive() throws {
        let plan = try XCTUnwrap(gestureFrames(surface(workspace()), offset: 300))
        XCTAssertEqual(plan.visible[id(1)]?.minX, -292)
        XCTAssertEqual(plan.visible[id(2)]?.minX, 316)
        XCTAssertEqual(plan.visible[id(3)]?.minX, 924, "peeking in from the right edge: visible")
        XCTAssertEqual(plan.parked[id(4)]?.frame.minX, 999, "still off screen: parked at the right sliver")
        let later = try XCTUnwrap(gestureFrames(surface(workspace()), offset: 900))
        XCTAssertNotNil(later.visible[id(4)], "column 4 arrived")
        XCTAssertEqual(later.parked[id(1)]?.edge, .left)
    }

    func testVisualOffsetFollowsWhereTheWindowsAreMidFlight() {
        let layout = [id(2): CGRect(x: 316, y: 8, width: 600, height: 784)]
        let physical = [id(2): CGRect(x: 356, y: 8, width: 600, height: 784)]
        XCTAssertEqual(
            gestureVisualOffset(committed: 300, visible: layout, physical: physical, prefer: id(2)), 260,
            "the window still lags 40 pt behind its target"
        )
        XCTAssertEqual(gestureVisualOffset(committed: 300, visible: layout, physical: [:], prefer: id(2)), 300)
    }

    // MARK: - Snap

    private func strip(_ ws: Workspace? = nil, centering: Bool = false) -> GestureStrip {
        gestureStrip(surface(ws ?? workspace(), centering: centering))!
    }

    func testReleaseWithoutVelocitySnapsToTheNearestColumnEdge() {
        // Snap points: 0 (c1), 224 (c2 right edge), 608 (c2 left), 832, 1216, 1440 (c4).
        XCTAssertEqual(snapGestureScroll(strip(), offset: 300, velocity: 0), GestureSnap(offset: 224, column: 1))
        XCTAssertEqual(snapGestureScroll(strip(), offset: 700, velocity: 0), GestureSnap(offset: 608, column: 1))
    }

    func testReleaseVelocityProjectsTheLanding() {
        // 300 + 1000 * 0.3328 = 632.8 lands on 608 (the left edge of column 2).
        XCTAssertEqual(snapGestureScroll(strip(), offset: 300, velocity: 1000), GestureSnap(offset: 608, column: 1))
        XCTAssertEqual(gestureProjectionSeconds, 0.3328, accuracy: 0.0001)
    }

    func testProjectionPastTheStripEndsStopsAtTheFirstAndLastColumn() {
        XCTAssertEqual(snapGestureScroll(strip(), offset: 1440, velocity: 9000), GestureSnap(offset: 1440, column: 3))
        XCTAssertEqual(snapGestureScroll(strip(), offset: 0, velocity: -9000), GestureSnap(offset: 0, column: 0))
    }

    func testFocusGoesToTheFurthestFullyVisibleColumnInTheSwipesDirection() {
        // Three 300 pt columns fit: one snap point (0); the swipe's direction picks the end.
        let fits = strip(workspace(columns: 3, width: 300))
        XCTAssertEqual(snapGestureScroll(fits, offset: 0, velocity: 400), GestureSnap(offset: 0, column: 2))
        XCTAssertEqual(snapGestureScroll(fits, offset: 0, velocity: -400), GestureSnap(offset: 0, column: 0))
    }

    func testCenteredStripsSnapToCenteredColumns() {
        // Centers 308, 916, 1524, 2132 minus half the viewport, clamped.
        XCTAssertEqual(
            snapGestureScroll(strip(centering: true), offset: 400, velocity: 0), GestureSnap(offset: 416, column: 1)
        )
        XCTAssertEqual(
            snapGestureScroll(strip(centering: true), offset: 1400, velocity: 0), GestureSnap(offset: 1440, column: 3)
        )
    }

    // MARK: - Commit and hand-off

    func testCommitStoresTheOffsetAndFocusesTheSnappedColumnOnItsDisplay() throws {
        var manager = WorkspaceManager()
        let left = DisplayID(1), right = DisplayID(2)
        manager.syncDisplays([left, right])
        var ws = manager.currentWorkspace()
        ws.columns = workspace().columns
        ws.focusedWindow = id(1)
        manager.update(ws)
        XCTAssertTrue(manager.focus(manager.activeID(on: right)!))

        let changed = commitGestureScroll(
            &manager, display: left, workspace: ws.id,
            strip: strip(), snap: GestureSnap(offset: 608, column: 1)
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(manager.focusedDisplay, left, "the display the fingers moved takes the focus")
        let committed = try XCTUnwrap(manager.workspace(id: ws.id))
        XCTAssertEqual(committed.viewportOffset, 608)
        XCTAssertEqual(committed.focusedColumn, 1)
        XCTAssertEqual(committed.focusedWindow, id(2))

        XCTAssertFalse(
            commitGestureScroll(&manager, display: left, workspace: ws.id, strip: strip(), snap: GestureSnap(offset: 224, column: 1)),
            "same column: only the offset changes"
        )
        XCTAssertEqual(manager.workspace(id: ws.id)?.viewportOffset, 224)
    }

    func testCommitToAVanishedWorkspaceChangesNothing() {
        var manager = WorkspaceManager()
        manager.syncDisplays([DisplayID(1)])
        let before = manager.currentWorkspace()
        XCTAssertFalse(commitGestureScroll(
            &manager, display: DisplayID(1), workspace: WorkspaceID(999), strip: strip(), snap: GestureSnap(offset: 10, column: 0)
        ))
        XCTAssertEqual(manager.currentWorkspace(), before)
    }

    func testReleaseVelocityIsHandedToTheGesturesSprings() {
        let spring = SpringParameters.niri
        let from = CGRect(x: 100, y: 8, width: 600, height: 784)
        let mine = WindowAnimation(id: id(1), from: from, to: from.offsetBy(dx: -84, dy: 0), spring: spring)
        let other = WindowAnimation(id: id(9), from: from, to: from.offsetBy(dx: 50, dy: 0), spring: spring)
        let eased = WindowAnimation(id: id(2), from: from, to: from.offsetBy(dx: -84, dy: 0), duration: 0.2)
        let handed = handingOffGestureVelocity([mine, other, eased], windows: [id(1), id(2)], velocity: -1200)
        XCTAssertEqual(handed[0].velocity, CGPoint(x: -1200, y: 0))
        XCTAssertNotEqual(handed[0].duration, mine.duration, "the settle time accounts for the velocity")
        XCTAssertEqual(handed[1], other, "windows of other workspaces keep theirs")
        XCTAssertEqual(handed[2], eased, "an eased flight has no velocity to take")
    }

    // MARK: - Workspace swipe

    func testWorkspaceSwipeFollowsTheNaturalSetting() {
        XCTAssertEqual(workspaceSwipeAction(.up, natural: true), .focusWorkspaceDown)
        XCTAssertEqual(workspaceSwipeAction(.down, natural: true), .focusWorkspaceUp)
        XCTAssertEqual(workspaceSwipeAction(.up, natural: false), .focusWorkspaceUp)
        XCTAssertEqual(workspaceSwipeAction(.down, natural: false), .focusWorkspaceDown)
    }
}
