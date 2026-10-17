import XCTest
@testable import GioCore

/// PF-AO: an instant pass writes every plan (each display, then the hidden
/// workspaces) in one reconcile; the merge keeps today's per-plan order.
final class PassWritesMergeTests: XCTestCase {
    private func id(_ pid: pid_t, _ element: UInt64) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let left = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let right = CGRect(x: 1800, y: 0, width: 1800, height: 1000)

    private func parked(_ x: CGFloat, display: CGRect) -> ParkedTarget {
        ParkedTarget(frame: CGRect(x: x, y: 8, width: 600, height: 984), edge: .right, display: display)
    }

    func testTwoDisplaysMergeIntoOneWriteSet() {
        let first = ParkingPlan(
            visible: [id(1, 1): CGRect(x: 8, y: 8, width: 900, height: 984)],
            parked: [id(1, 2): parked(1799, display: left)]
        )
        let second = ParkingPlan(
            visible: [id(2, 1): CGRect(x: 1808, y: 8, width: 900, height: 984)],
            parked: [id(2, 2): parked(3599, display: right)]
        )
        let merged = mergePassWrites([first, second], focus: nil)
        XCTAssertEqual(merged.plan.visible, first.visible.merging(second.visible) { $1 })
        XCTAssertEqual(merged.plan.parked, first.parked.merging(second.parked) { $1 })
        XCTAssertNil(merged.focus)
    }

    func testDuplicateWindowTakesTheLaterPlan() {
        let window = id(1, 1)
        let early = CGRect(x: 8, y: 8, width: 900, height: 984)
        let late = CGRect(x: 1808, y: 8, width: 900, height: 984)
        let sameKind = mergePassWrites(
            [ParkingPlan(visible: [window: early]), ParkingPlan(visible: [window: late])], focus: nil
        )
        XCTAssertEqual(sameKind.plan.visible, [window: late])
        XCTAssertTrue(sameKind.plan.parked.isEmpty)

        // Visible first, parked later: parked (the later write) wins.
        let parkedLater = mergePassWrites(
            [ParkingPlan(visible: [window: early]), ParkingPlan(parked: [window: parked(1799, display: left)])],
            focus: nil
        )
        XCTAssertTrue(parkedLater.plan.visible.isEmpty)
        XCTAssertEqual(parkedLater.plan.parked, [window: parked(1799, display: left)])

        // Parked first, visible later: visible (the later write) wins.
        let visibleLater = mergePassWrites(
            [ParkingPlan(parked: [window: parked(1799, display: left)]), ParkingPlan(visible: [window: late])],
            focus: nil
        )
        XCTAssertEqual(visibleLater.plan.visible, [window: late])
        XCTAssertTrue(visibleLater.plan.parked.isEmpty)
    }

    func testFocusTargetIsCarriedOnce() {
        let target = id(2, 1)
        let merged = mergePassWrites(
            [
                ParkingPlan(visible: [id(1, 1): CGRect(x: 8, y: 8, width: 900, height: 984)]),
                ParkingPlan(visible: [target: CGRect(x: 1808, y: 8, width: 900, height: 984)]),
                ParkingPlan(parked: [id(3, 1): parked(3599, display: right)]),
            ],
            focus: target
        )
        XCTAssertEqual(merged.focus, target)
        XCTAssertEqual(merged.plan.visible.count, 2)
    }

    func testHiddenWorkspaceParkingIsKeptAndWrittenBeforeVisiblePerApp() {
        // Display plan shows window 1:1; the hidden-workspace plan parks 1:2
        // of the same app. One lane per app, parked before visible.
        let shown = ParkingPlan(visible: [id(1, 1): CGRect(x: 8, y: 8, width: 900, height: 984)])
        let hidden = ParkingPlan(parked: [id(1, 2): parked(1799, display: left), id(2, 5): parked(1799, display: left)])
        let merged = mergePassWrites([shown, hidden], focus: nil)
        XCTAssertEqual(merged.plan.parked, hidden.parked)
        let lanes = planWriteLanes(frames: merged.plan.visible, parked: merged.plan.parked)
        XCTAssertEqual(lanes.map(\.pid), [1, 2])
        XCTAssertEqual(lanes[0].items.map(\.id), [id(1, 2), id(1, 1)])
        XCTAssertNotNil(lanes[0].items[0].parked)
        XCTAssertNil(lanes[0].items[1].parked)
    }

    func testNoPlansIsEmpty() {
        let merged = mergePassWrites([], focus: nil)
        XCTAssertEqual(merged.plan, ParkingPlan())
        XCTAssertNil(merged.focus)
    }
}
