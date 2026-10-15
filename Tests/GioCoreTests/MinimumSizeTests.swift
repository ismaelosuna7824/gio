import XCTest
@testable import GioCore

/// FI-02: apps clamp to an unpublished minimum size. A clamp is learned per
/// window, the layout honours it, and the next pass converges without
/// failures.
final class MinimumSizeTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    // MARK: Learning rule

    func testWidthClampWithSameOriginIsLearned() {
        let learned = learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 784),
            actual: CGRect(x: 8, y: 8, width: 500, height: 784)
        )
        XCTAssertEqual(learned, CGSize(width: 500, height: 0))
    }

    func testHeightClampIsLearnedIndependently() {
        let learned = learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 300),
            actual: CGRect(x: 8, y: 8, width: 440, height: 380)
        )
        XCTAssertEqual(learned, CGSize(width: 0, height: 380))
    }

    func testBothDimensionsLearned() {
        let learned = learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 300),
            actual: CGRect(x: 8, y: 8, width: 500, height: 380)
        )
        XCTAssertEqual(learned, CGSize(width: 500, height: 380))
    }

    func testGrowthAnchoredToFarEdgeIsStillAClamp() {
        // Cocoa y-up: a top-anchored window that grows keeps maxY, lowers minY.
        let learned = learnedMinimum(
            requested: CGRect(x: 8, y: 400, width: 440, height: 300),
            actual: CGRect(x: 8, y: 320, width: 440, height: 380)
        )
        XCTAssertEqual(learned, CGSize(width: 0, height: 380))
        // Right-anchored width growth keeps maxX, lowers minX.
        let right = learnedMinimum(
            requested: CGRect(x: 100, y: 8, width: 440, height: 784),
            actual: CGRect(x: 40, y: 8, width: 500, height: 784)
        )
        XCTAssertEqual(right, CGSize(width: 500, height: 0))
    }

    func testPositionClampWithoutGrowthIsNotLearned() {
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: 1500, y: 8, width: 440, height: 784),
            actual: CGRect(x: 1360, y: 8, width: 440, height: 784)
        ))
    }

    func testGrowthWithShiftedBothEdgesIsPositionClampNotLearned() {
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: 1500, y: 8, width: 440, height: 784),
            actual: CGRect(x: 1400, y: 8, width: 480, height: 784)
        ))
    }

    func testSmallerOrEqualOrNoiseIsNotLearned() {
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 300),
            actual: CGRect(x: 8, y: 8, width: 400, height: 250)
        ))
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 300),
            actual: CGRect(x: 8, y: 8, width: 441, height: 300.5)
        ))
    }

    /// MM-11 live (TextEdit sent to the external display five times): each
    /// landing kept the top at the built-in display's visible top (height
    /// 1394 -> 1130) and came back 32 pt wider; learning that width made the
    /// column 32 pt wider on every move (1068, 1100, 1132, 1164, 1196). A
    /// window that landed smaller in the other dimension was constrained to
    /// a screen, which says nothing about its minimum size.
    func testGrowthWhileTheOtherDimensionShrankIsAScreenConstraintNotLearned() {
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: -1076, y: -216, width: 1068, height: 1394),
            actual: CGRect(x: -1076, y: 0, width: 1100, height: 1130)
        ))
        XCTAssertNil(learnedMinimum(
            requested: CGRect(x: 8, y: 8, width: 440, height: 784),
            actual: CGRect(x: 8, y: 8, width: 360, height: 900)
        ))
    }

    // MARK: Book

    func testBookKeepsMaximumAndReportsChange() {
        var book = MinimumSizeBook()
        let requested = CGRect(x: 8, y: 8, width: 440, height: 784)
        XCTAssertEqual(
            book.learn(id(1), requested: requested, actual: CGRect(x: 8, y: 8, width: 500, height: 784)),
            CGSize(width: 500, height: 0)
        )
        XCTAssertNil(book.learn(id(1), requested: requested, actual: CGRect(x: 8, y: 8, width: 500, height: 784)))
        XCTAssertNil(book.learn(id(1), requested: requested, actual: CGRect(x: 8, y: 8, width: 470, height: 784)))
        XCTAssertEqual(
            book.learn(id(1), requested: requested, actual: CGRect(x: 8, y: 8, width: 520, height: 784)),
            CGSize(width: 520, height: 0)
        )
        XCTAssertEqual(book.size(of: id(1)), CGSize(width: 520, height: 0))
        book.forget(id(1))
        XCTAssertNil(book.size(of: id(1)))
    }

    func testBookLearnsOnlyFromFrameMismatchFailures() {
        var book = MinimumSizeBook()
        let requested = CGRect(x: 8, y: 8, width: 440, height: 784)
        let actual = CGRect(x: 8, y: 8, width: 500, height: 784)
        let report = ReconcileReport(
            failed: [id(1), id(2)],
            failures: [
                id(1): ReconcileFailure(kind: "frameMismatch", requested: requested, actual: actual),
                id(2): ReconcileFailure(kind: "timeout", requested: requested, actual: actual),
            ]
        )
        let changed = book.learn(from: report, placement: .animate)
        XCTAssertEqual(changed, [id(1): CGSize(width: 500, height: 0)])
        XCTAssertNil(book.size(of: id(2)))
    }

    /// Live (2026-10-09): Slack and OrbStack were written from 1068 to 888
    /// in the pass after a display change, landed at 1068 and were learned
    /// as 1068 wide for the session; every column pair holding them then
    /// overflowed the screen and each focus change re-centered the strip.
    func testDisplayChangePassTeachesNoMinimum() {
        let report = ReconcileReport(
            failed: [id(1)],
            failures: [
                id(1): ReconcileFailure(
                    kind: "frameMismatch", requested: CGRect(x: 8, y: 8, width: 888, height: 1114),
                    actual: CGRect(x: 8, y: 8, width: 1068, height: 1114)
                ),
            ]
        )
        var book = MinimumSizeBook()
        XCTAssertTrue(book.learn(from: report, placement: .instant(.displays)).isEmpty)
        XCTAssertNil(book.size(of: id(1)))
        // The same clamp in any other pass is still evidence.
        for placement in [InstantPlacementDecision.animate, .instant(nil), .instant(.startup), .instant(.mouse)] {
            var other = MinimumSizeBook()
            XCTAssertEqual(other.learn(from: report, placement: placement), [id(1): CGSize(width: 1068, height: 0)])
        }
    }

    /// FI-11: a clamp the app applies after Gio's read-back is seen by the
    /// late re-check (requested = Gio's last write, actual = the frame read
    /// once its echo window ended). A write of a display-change pass still
    /// teaches nothing; a later write of any other pass does again.
    func testALateClampIsLearnedUnlessADisplayPassWroteTheWindow() {
        let requested = CGRect(x: 8, y: 8, width: 888, height: 1114)
        let actual = CGRect(x: 8, y: 8, width: 1068, height: 1114)
        var book = MinimumSizeBook()
        book.notePlaced([id(1)], placement: .instant(.displays))
        XCTAssertNil(book.learnLate(id(1), requested: requested, actual: actual))
        book.notePlaced([id(1)], placement: .animate)
        XCTAssertEqual(book.learnLate(id(1), requested: requested, actual: actual), CGSize(width: 1068, height: 0))
        XCTAssertNil(book.learnLate(id(1), requested: requested, actual: actual), "nothing new")
        XCTAssertNil(
            book.learnLate(id(2), requested: requested, actual: actual.offsetBy(dx: 40, dy: 0).insetBy(dx: -20, dy: 0)),
            "pushed, not clamped"
        )
        book.notePlaced([id(3)], placement: .instant(.displays))
        book.forget(id(3))
        XCTAssertNotNil(book.learnLate(id(3), requested: requested, actual: actual), "forgotten with the window")
    }

    // MARK: Layout

    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func workspace(_ columns: [Column]) -> Workspace {
        Workspace(id: WorkspaceID(1), columns: columns)
    }

    private func column(_ id: UInt64, width: CGFloat, _ windows: [WindowID]) -> Column {
        Column(id: ColumnID(id), width: width, windows: windows, focusedWindowIndex: 0)
    }

    func testColumnWidthGrowsToWidestMemberMinimumAndShiftsNeighbours() throws {
        let engine = ScrollableLayoutEngine(minimumSizes: [id(1): CGSize(width: 500, height: 0)])
        let result = try engine.calculate(
            workspace: workspace([column(1, width: 300, [id(1)]), column(2, width: 300, [id(2)])]),
            viewport: viewport
        )
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 8, y: 8, width: 500, height: 784))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 516, y: 8, width: 300, height: 784))
        XCTAssertEqual(result.contentWidth, 8 + 500 + 8 + 300 + 8)
    }

    func testMinimumSmallerThanSpecChangesNothing() throws {
        let engine = ScrollableLayoutEngine(minimumSizes: [id(1): CGSize(width: 200, height: 100)])
        let result = try engine.calculate(
            workspace: workspace([column(1, width: 300, [id(1)])]), viewport: viewport
        )
        XCTAssertEqual(result.frames[id(1)]?.width, 300)
    }

    func testMinimumWidthIsCappedToUsableViewport() throws {
        let engine = ScrollableLayoutEngine(minimumSizes: [id(1): CGSize(width: 5000, height: 0)])
        let result = try engine.calculate(
            workspace: workspace([column(1, width: 300, [id(1)])]), viewport: viewport
        )
        XCTAssertEqual(result.frames[id(1)]?.width, 984)
    }

    func testStackedHeightsRespectMinimumWhereColumnAllows() throws {
        let engine = ScrollableLayoutEngine(minimumSizes: [id(1): CGSize(width: 0, height: 600)])
        let result = try engine.calculate(
            workspace: workspace([column(1, width: 400, [id(1), id(2)])]), viewport: viewport
        )
        // Usable 784 minus one gap = 776: window 1 takes its 600, window 2 the rest.
        XCTAssertEqual(result.frames[id(1)], CGRect(x: 8, y: 8, width: 400, height: 600))
        XCTAssertEqual(result.frames[id(2)], CGRect(x: 8, y: 616, width: 400, height: 176))
    }

    func testStackedHeightsFallBackToProportionalWhenMinimumsCannotFit() throws {
        let engine = ScrollableLayoutEngine(minimumSizes: [
            id(1): CGSize(width: 0, height: 600), id(2): CGSize(width: 0, height: 600),
        ])
        let result = try engine.calculate(
            workspace: workspace([column(1, width: 400, [id(1), id(2)])]), viewport: viewport
        )
        XCTAssertEqual(result.frames[id(1)]?.height, 388)
        XCTAssertEqual(result.frames[id(2)]?.height, 388)
    }

    func testDistributeHeightsKeepsWeightsWhenMinimumsAreSatisfied() {
        XCTAssertEqual(
            distributeHeights(available: 300, weights: [1, 2], minimums: [50, 50]), [100, 200]
        )
    }

    func testDistributeHeightsRedistributesAfterClamping() {
        // Weights 1:1:2 over 400 = 100/100/200; the first needs 250, so the
        // other two split the remaining 150 in their 1:2 ratio.
        let heights = distributeHeights(available: 400, weights: [1, 1, 2], minimums: [250, 0, 0])
        XCTAssertEqual(heights[0], 250, accuracy: 0.001)
        XCTAssertEqual(heights[1], 50, accuracy: 0.001)
        XCTAssertEqual(heights[2], 100, accuracy: 0.001)
        XCTAssertEqual(heights.reduce(0, +), 400, accuracy: 0.001)
    }

    // MARK: Convergence

    /// Stands in for an app that refuses to be narrower/shorter than a
    /// minimum: the write lands clamped (left/top anchored) and reports the
    /// landing mismatch like the AX actuator does.
    private final class ClampingActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var minimums: [WindowID: CGSize] = [:]
        var sets = 0

        func frame(of id: WindowID) throws -> CGRect? { frames[id] }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            sets += 1
            let floor = minimums[id] ?? .zero
            let landed = CGRect(
                x: frame.minX, y: frame.minY,
                width: max(frame.width, floor.width), height: max(frame.height, floor.height)
            )
            frames[id] = landed
            if landed != frame {
                throw FrameWriteError.mismatch(actual: landed)
            }
        }

        func focus(id: WindowID) throws {}
    }

    func testReconcileLearnRelayoutReconcileConverges() throws {
        let actuator = ClampingActuator()
        actuator.minimums = [id(1): CGSize(width: 500, height: 0)]
        actuator.frames = [
            id(1): CGRect(x: 0, y: 0, width: 100, height: 100),
            id(2): CGRect(x: 0, y: 0, width: 100, height: 100),
        ]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let ws = workspace([column(1, width: 300, [id(1)]), column(2, width: 300, [id(2)])])
        var book = MinimumSizeBook()

        func pass() throws -> ReconcileReport {
            let engine = ScrollableLayoutEngine(minimumSizes: book.sizes)
            let layout = try engine.calculate(workspace: ws, viewport: viewport)
            return reconciler.reconcile(frames: layout.frames, focused: nil, currentlyFocused: nil)
        }

        let first = try pass()
        XCTAssertEqual(first.failed, [id(1)])
        XCTAssertEqual(book.learn(from: first, placement: .instant(nil)).keys.sorted(), [id(1)])

        let second = try pass()
        XCTAssertTrue(second.failed.isEmpty)
        let a = try XCTUnwrap(actuator.frames[id(1)])
        let b = try XCTUnwrap(actuator.frames[id(2)])
        XCTAssertFalse(a.intersects(b))
        XCTAssertEqual(a.width, 500)

        let writesBefore = actuator.sets
        let third = try pass()
        XCTAssertTrue(third.failed.isEmpty)
        XCTAssertEqual(third.alreadyCorrect.count, 2)
        XCTAssertEqual(actuator.sets, writesBefore)
        XCTAssertTrue(book.learn(from: third, placement: .instant(nil)).isEmpty)
    }

    /// WC-14: live (2026-10-15, startup): WhatsApp refuses to be narrower than
    /// 970 pt, its column is 888, and the left parking frame put it at
    /// x = -887 for 888 pt, so 83 pt of it stayed on screen over the first
    /// visible column. A left-parked window is placed by its landed width.
    func testAWindowParkedOnTheLeftAtItsClampedWidthKeepsOnlyTheSliver() throws {
        let actuator = ClampingActuator()
        actuator.minimums = [id(1): CGSize(width: 970, height: 0)]
        actuator.frames = [id(1): CGRect(x: 100, y: 8, width: 970, height: 1114)]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let target = ParkedTarget(
            frame: CGRect(x: display.minX - 888 + parkingSliver, y: 8, width: 888, height: 1114),
            edge: .left, display: display
        )

        let report = reconciler.reconcile(frames: [:], parked: [id(1): target], focused: nil, currentlyFocused: nil)

        let landed = try XCTUnwrap(actuator.frames[id(1)])
        XCTAssertEqual(landed.width, 970)
        XCTAssertEqual(landed.maxX, display.minX + parkingSliver, accuracy: 0.5)
        XCTAssertEqual(report.parked, [id(1)])
        XCTAssertTrue(report.failed.isEmpty)
    }

    /// WC-14: the right edge parks by the left side of the window, whatever
    /// width it lands at: nothing to refit, no extra write.
    func testAWindowParkedOnTheRightAtItsClampedWidthNeedsNoRefit() throws {
        let actuator = ClampingActuator()
        actuator.minimums = [id(1): CGSize(width: 970, height: 0)]
        actuator.frames = [id(1): CGRect(x: 100, y: 8, width: 970, height: 1114)]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let target = ParkedTarget(
            frame: CGRect(x: display.maxX - parkingSliver, y: 8, width: 888, height: 1114), edge: .right, display: display
        )

        let report = reconciler.reconcile(frames: [:], parked: [id(1): target], focused: nil, currentlyFocused: nil)

        XCTAssertEqual(actuator.frames[id(1)]?.minX, display.maxX - parkingSliver)
        XCTAssertEqual(actuator.sets, 1)
        XCTAssertEqual(report.parked, [id(1)])
    }
}
