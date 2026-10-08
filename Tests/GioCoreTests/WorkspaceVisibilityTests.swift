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

    // MARK: MM-03 hidden windows never land on another display

    func testBothBottomCornersBlockedHangOffTheFreeSide() {
        let below = CGRect(x: -3000, y: -2000, width: 8000, height: 2000)
        let target = hiddenTarget(for: frame, display: display, otherDisplays: [below])
        XCTAssertEqual(target.edge, .right)
        XCTAssertEqual(target.display, display)
        XCTAssertEqual(target.frame.size, frame.size)
        XCTAssertEqual(target.frame.minX, display.maxX - parkingSliver)
        XCTAssertEqual(target.frame.maxY, display.maxY, "level with the display's top")
        XCTAssertFalse(below.intersects(target.frame))
        XCTAssertTrue(isParked(target.frame, target, 1))
    }

    func testBottomCornersAndRightSideBlockedHangOffTheLeftSide() {
        let below = CGRect(x: -3000, y: -2000, width: 8000, height: 2000)
        let right = CGRect(x: 1800, y: 0, width: 1200, height: 1000)
        let target = hiddenTarget(for: frame, display: display, otherDisplays: [below, right])
        XCTAssertEqual(target.edge, .left)
        XCTAssertEqual(target.frame.maxX, display.minX + parkingSliver)
        XCTAssertFalse([below, right].contains { $0.intersects(target.frame) })
        XCTAssertTrue(isParked(target.frame, target, 1))
    }

    func testEverySideBlockedHangsOffTheBottomRightOfAllDisplays() {
        let others = [
            CGRect(x: -3000, y: -2000, width: 8000, height: 2000),
            CGRect(x: -3000, y: 0, width: 3000, height: 1000),
            CGRect(x: 1800, y: 0, width: 3000, height: 1000),
        ]
        let target = hiddenTarget(for: frame, display: display, otherDisplays: others)
        let union = others.reduce(display) { $0.union($1) }
        XCTAssertEqual(target.edge, .corner)
        XCTAssertEqual(target.frame.size, frame.size)
        XCTAssertEqual(target.frame.minX, union.maxX - parkingSliver)
        XCTAssertEqual(target.frame.maxY, union.minY + parkingSliver)
        for other in others {
            let overlap = other.intersection(target.frame)
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height <= parkingSliver * parkingSliver)
        }
        XCTAssertTrue(isParked(target.frame, target, 1))
    }

    func testHiddenWindowsOfAnUpperDisplayNeverLandOnTheDisplayBelow() {
        let lower = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let window = CGRect(x: 100, y: 1177, width: 900, height: 1000)
        for upper in [
            CGRect(x: 0, y: 1169, width: 1920, height: 1080),
            CGRect(x: 0, y: 1169, width: 1800, height: 1080),
            CGRect(x: -200, y: 1169, width: 2400, height: 1080),
        ] {
            let target = hiddenTarget(for: window, display: upper, otherDisplays: [lower])
            XCTAssertFalse(lower.intersects(target.frame), "\(upper) -> \(target.frame)")
            XCTAssertTrue(isParked(target.frame, target, 1), "\(upper)")
        }
    }

    func testSideBySideDisplaysKeepTheBottomCorners() {
        let right = CGRect(x: 1800, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            hiddenTarget(for: frame, display: display, otherDisplays: [right]).frame.maxX,
            display.minX + parkingSliver
        )
        let target = hiddenTarget(for: frame, display: right, otherDisplays: [display])
        XCTAssertEqual(target.edge, .corner)
        XCTAssertEqual(target.frame.minX, right.maxX - parkingSliver)
        XCTAssertEqual(target.frame.maxY, right.minY + parkingSliver)
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
        var first = manager.currentWorkspace()
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [id(1)])]
        manager.update(first)
        XCTAssertTrue(manager.focusDown())
        var second = manager.currentWorkspace()
        second.columns = [Column(id: ColumnID(1), width: 300, windows: [id(3), id(4)])]
        manager.update(second)
        XCTAssertEqual(manager.windows(outside: [first.id]), [id(3), id(4)])
        XCTAssertEqual(manager.windows(outside: [second.id]), [id(1)])
        XCTAssertEqual(manager.windows(outside: [first.id, second.id]), [])
    }

    func testMovedWindowJoinsHiddenSetWhenTargetIsNotShown() {
        var manager = WorkspaceManager()
        var first = manager.currentWorkspace()
        first.columns = [
            Column(id: ColumnID(1), width: 300, windows: [id(1)]),
            Column(id: ColumnID(2), width: 300, windows: [id(2)]),
        ]
        first.focusedColumn = 1
        first.focusedWindow = id(2)
        manager.update(first)
        XCTAssertTrue(manager.moveWindow(id(2), to: 4))   // beyond the stack: the spare
        XCTAssertEqual(manager.windows(outside: [first.id]), [id(2)])
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

    func testBookPeekKeepsTheMemoryUntilRevealed() {
        // A retarget mid-flight must still find the floating window's frame.
        var book = HiddenWindowBook()
        book.hide(id(1), from: frame)
        XCTAssertEqual(book.frames(of: [id(1), id(9)]), [id(1): frame])
        XCTAssertEqual(book.frames(of: [id(1)]), [id(1): frame])
        XCTAssertEqual(book.reveal([id(1)]), [id(1): frame])
    }

    func testBookMoveReplacesTheRememberedFrame() {
        var book = HiddenWindowBook()
        let moved = CGRect(x: 1900, y: 100, width: 700, height: 984)
        book.hide(id(1), from: frame)
        book.move(id(1), to: moved)
        XCTAssertEqual(book.frames(of: [id(1)]), [id(1): moved])
        book.move(id(2), to: moved)
        XCTAssertTrue(book.isHidden(id(2)), "a shown window that must move is remembered too")
        XCTAssertEqual(book.reveal([id(1), id(2)]), [id(1): moved, id(2): moved])
    }

    // MARK: MM-03 floating windows follow their workspace to another display

    private let leftVisible = CGRect(x: 0, y: 25, width: 1800, height: 1100)
    private let rightVisible = CGRect(x: 1800, y: 25, width: 1600, height: 950)

    func testRelocatedFloatingFrameKeepsSizeAndOffsetFromTheVisibleOrigin() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertEqual(
            relocatedFloatingFrame(window, from: leftVisible, to: rightVisible),
            CGRect(x: 1900, y: 100, width: 600, height: 400)
        )
    }

    func testRelocatedFloatingFrameIsClampedInsideTheTarget() {
        let window = CGRect(x: 1500, y: 800, width: 600, height: 400)
        XCTAssertEqual(
            relocatedFloatingFrame(window, from: leftVisible, to: rightVisible),
            CGRect(x: 2800, y: 575, width: 600, height: 400)
        )
        let huge = CGRect(x: 0, y: 25, width: 2000, height: 1100)
        let landed = relocatedFloatingFrame(huge, from: leftVisible, to: rightVisible)
        XCTAssertEqual(landed.size, huge.size, "size is kept even when it does not fit")
        XCTAssertEqual(landed.minX, rightVisible.minX)
        XCTAssertEqual(landed.maxY, rightVisible.maxY, "the title bar stays reachable")
    }

    func testOnlyFloatingWindowsWhoseDisplayChangedAreRelocated() {
        let left = DisplayID(1), right = DisplayID(2), gone = DisplayID(3)
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        let alreadyThere = CGRect(x: 2000, y: 100, width: 600, height: 400)
        let moves = planFloatingRelocations(
            frames: [id(1): window, id(2): window, id(3): alreadyThere, id(4): window, id(6): window],
            previous: [id(1): left, id(2): left, id(3): left, id(4): gone, id(5): left, id(6): right],
            current: [id(1): right, id(2): left, id(3): right, id(4): right, id(5): right, id(6): right],
            visibleFrames: [left: leftVisible, right: rightVisible]
        )
        // 2 and 6 stayed, 3 is already on the target, 4 left a display that
        // is gone, 5 has no frame.
        XCTAssertEqual(moves, [id(1): CGRect(x: 1900, y: 100, width: 600, height: 400)])
    }

    func testANewlySeenFloatingWindowIsNotRelocated() {
        let moves = planFloatingRelocations(
            frames: [id(1): frame], previous: [:], current: [id(1): DisplayID(2)],
            visibleFrames: [DisplayID(1): leftVisible, DisplayID(2): rightVisible]
        )
        XCTAssertTrue(moves.isEmpty)
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
