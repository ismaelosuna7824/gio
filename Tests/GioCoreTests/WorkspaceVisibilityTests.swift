import XCTest
@testable import GioCore

/// NC-06: windows of inactive workspaces hang off a display corner, never
/// colliding with side parking or another display, and always come back.
final class WorkspaceVisibilityTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let frame = CGRect(x: 100, y: 8, width: 700, height: 984)

    // MARK: hidden position

    func testHiddenWindowHangsOffTheBottomRightCornerKeepingSize() {
        let target = hiddenTarget(for: frame, display: display, otherDisplays: [])
        XCTAssertEqual(target.edge, .corner)
        XCTAssertEqual(target.display, display)
        XCTAssertEqual(target.frame.size, frame.size)
        XCTAssertEqual(target.frame.minX, display.maxX - parkingSliver)
        XCTAssertEqual(target.frame.maxY, display.minY + parkingSliver)
    }

    func testHiddenPositionNeverTouchesSideParkingBand() {
        // Side parking keeps the window's own y inside the display; the
        // hidden position is entirely below it (only the sliver overlaps).
        let hidden = hiddenTarget(for: frame, display: display, otherDisplays: []).frame
        let sideParked = planParking(
            frames: [id(1): CGRect(x: 2000, y: 8, width: 700, height: 984)],
            viewport: display, display: display, otherDisplays: []
        ).parked[id(1)]!.frame
        XCTAssertLessThanOrEqual(hidden.maxY, display.minY + parkingSliver)
        XCTAssertFalse(hidden.intersects(sideParked.insetBy(dx: 0, dy: 0.5)))
    }

    func testBottomRightBlockedByNeighbourUsesBottomLeft() {
        let right = CGRect(x: 1800, y: -1000, width: 1200, height: 2000)
        let target = hiddenTarget(for: frame, display: display, otherDisplays: [right])
        XCTAssertEqual(target.edge, .corner)
        XCTAssertEqual(target.frame.maxX, display.minX + parkingSliver)
        XCTAssertFalse(right.intersects(target.frame))
    }

    func testAllCornersBlockedFallsBackToBottomRight() {
        let below = CGRect(x: -3000, y: -2000, width: 8000, height: 2000)
        let target = hiddenTarget(for: frame, display: display, otherDisplays: [below])
        XCTAssertEqual(target.edge, .corner)
        XCTAssertEqual(target.frame.minX, display.maxX - parkingSliver)
    }

    func testPlanHiddenKeepsEachWindowsOwnSize() {
        let plan = planHiddenWindows(
            frames: [id(1): frame, id(2): CGRect(x: 0, y: 0, width: 300, height: 200)],
            display: display, otherDisplays: []
        )
        XCTAssertEqual(plan[id(1)]?.frame.size, frame.size)
        XCTAssertEqual(plan[id(2)]?.frame.size, CGSize(width: 300, height: 200))
    }

    func testReconcilerAcceptsBothHiddenCornersAsParked() {
        let right = hiddenTarget(for: frame, display: display, otherDisplays: [])
        XCTAssertTrue(isParked(right.frame, right, 1))
        let clamped = CGRect(x: 1790, y: -970, width: 700, height: 984)
        XCTAssertTrue(isParked(clamped, right, 1))
        let left = hiddenTarget(
            for: frame, display: display,
            otherDisplays: [CGRect(x: 1800, y: -1000, width: 1200, height: 2000)]
        )
        XCTAssertTrue(isParked(left.frame, left, 1))
    }

    // MARK: restore covers hidden windows

    func testRestorePlannerBringsHiddenCornerWindowsBack() throws {
        let restoreDisplay = RestoreDisplay(frame: display, visibleFrame: display)
        let hidden = hiddenTarget(for: frame, display: display, otherDisplays: []).frame
        let plan = planRestore(windows: [id(1): hidden], displays: [restoreDisplay])
        let restored = try XCTUnwrap(plan[id(1)])
        XCTAssertEqual(restored.size, hidden.size)
        XCTAssertTrue(display.contains(restored))
    }

    func testRestorePlannerBringsBottomLeftHiddenWindowsBack() throws {
        let neighbour = CGRect(x: 1800, y: -1000, width: 1200, height: 2000)
        let hidden = hiddenTarget(for: frame, display: display, otherDisplays: [neighbour]).frame
        let plan = planRestore(
            windows: [id(1): hidden],
            displays: [
                RestoreDisplay(frame: display, visibleFrame: display),
                RestoreDisplay(frame: neighbour, visibleFrame: neighbour),
            ]
        )
        XCTAssertNotNil(plan[id(1)])
    }

    // MARK: inactive membership

    func testWindowsOutsideShownWorkspacesAreTheHiddenSet() {
        var manager = WorkspaceManager()
        var first = manager.workspace(1)!
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [id(1)])]
        manager.update(first)
        var third = manager.workspace(3)!
        third.columns = [Column(id: ColumnID(1), width: 300, windows: [id(3), id(4)])]
        manager.update(third)
        XCTAssertEqual(manager.windows(outside: [1]), [id(3), id(4)])
        XCTAssertEqual(manager.windows(outside: [3]), [id(1)])
        XCTAssertEqual(manager.windows(outside: [1, 3]), [])
    }

    func testMovedWindowJoinsHiddenSetWhenTargetIsNotShown() {
        var manager = WorkspaceManager()
        var first = manager.workspace(1)!
        first.columns = [
            Column(id: ColumnID(1), width: 300, windows: [id(1)]),
            Column(id: ColumnID(2), width: 300, windows: [id(2)]),
        ]
        first.focusedColumn = 1
        first.focusedWindow = id(2)
        manager.update(first)
        XCTAssertTrue(manager.moveWindow(id(2), to: 4))
        XCTAssertEqual(manager.windows(outside: [1]), [id(2)])
        // Focus falls to the neighbour that stayed behind.
        XCTAssertEqual(manager.workspace(1)?.focusedWindow, id(1))
    }

    // MARK: floating memory

    func testBookRemembersOriginalFrameOnlyOnFirstHide() {
        var book = HiddenWindowBook()
        book.hide(id(1), from: frame)
        book.hide(id(1), from: CGRect(x: 1799, y: -983, width: 700, height: 984))
        XCTAssertTrue(book.isHidden(id(1)))
        XCTAssertEqual(book.reveal([id(1)]), [id(1): frame])
        XCTAssertFalse(book.isHidden(id(1)))
        XCTAssertTrue(book.reveal([id(1)]).isEmpty)
    }

    func testBookRevealIgnoresUnknownAndKeepsOthers() {
        var book = HiddenWindowBook()
        book.hide(id(1), from: frame)
        book.hide(id(2), from: frame)
        XCTAssertEqual(book.reveal([id(2), id(9)]), [id(2): frame])
        XCTAssertTrue(book.isHidden(id(1)))
    }

    // MARK: display follows the current workspace

    func testShowingCurrentWorkspaceReassignsTheDisplayThatShowedThePrevious() {
        var displays = DisplayManager()
        let a = DisplayID(1), b = DisplayID(2)
        displays.connect(a, frame: display, workspace: WorkspaceID(1))
        displays.connect(b, frame: CGRect(x: 1800, y: 0, width: 1200, height: 800), workspace: WorkspaceID(2))
        XCTAssertTrue(displays.show(WorkspaceID(5), replacing: WorkspaceID(2)))
        XCTAssertEqual(displays.display(a)?.workspace, WorkspaceID(1))
        XCTAssertEqual(displays.display(b)?.workspace, WorkspaceID(5))
    }

    func testShowingAlreadyVisibleWorkspaceChangesNothing() {
        var displays = DisplayManager()
        displays.connect(DisplayID(1), frame: display, workspace: WorkspaceID(3))
        XCTAssertFalse(displays.show(WorkspaceID(3), replacing: WorkspaceID(1)))
    }

    func testShowFallsBackToFirstDisplayWithoutPrevious() {
        var displays = DisplayManager()
        displays.connect(DisplayID(1), frame: display, workspace: WorkspaceID(1))
        XCTAssertTrue(displays.show(WorkspaceID(4), replacing: nil))
        XCTAssertEqual(displays.display(DisplayID(1))?.workspace, WorkspaceID(4))
    }
}
