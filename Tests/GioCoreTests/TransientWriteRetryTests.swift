import CoreGraphics
@testable import GioCore
import XCTest

/// MM-11: live with two displays (screen recording, 2026-10-15): Xcode was
/// sent to the external display while it was busy redrawing; its size write
/// timed out (`writeFailed(size,-25204)`, the 0.25 s messaging timeout), the
/// window stayed on the built-in display and nothing wrote it again, so it
/// sat on the wrong display until the next action touched it. A write that
/// failed only because the app did not answer in time is tried again once.
final class TransientWriteRetryTests: XCTestCase {
    private let xcode = WindowID(pid: 1, elementID: 1)
    private let figma = WindowID(pid: 2, elementID: 2)

    private func report(failed: [WindowID: String] = [:], applied: [WindowID] = []) -> ReconcileReport {
        var report = ReconcileReport()
        report.applied = applied
        report.failed = failed.keys.sorted()
        for (id, kind) in failed {
            report.failures[id] = ReconcileFailure(kind: kind)
        }
        return report
    }

    func testOnlyAppsThatDidNotAnswerInTimeAreTransient() {
        XCTAssertTrue(ReconcileFailure(kind: "timeout").isTransient)
        XCTAssertTrue(ReconcileFailure(kind: "writeFailed(size,-25204)").isTransient)
        XCTAssertTrue(ReconcileFailure(kind: "readbackFailed(position,-25204)").isTransient)
        XCTAssertFalse(ReconcileFailure(kind: ReconcileFailure.frameMismatchKind).isTransient, "the app refused the frame")
        XCTAssertFalse(ReconcileFailure(kind: "writeFailed(size,-25205)").isTransient)
        XCTAssertFalse(ReconcileFailure(kind: "notSettable(size)").isTransient)
    }

    /// Live (TextEdit under SIGSTOP): frozen 0.4 s, the 0.5 s retry landed it
    /// on the external display; frozen 1.3 s, that one retry timed out too
    /// and the window stayed on the built-in display. Retries back off so an
    /// app busy for a few seconds still lands, then stop.
    func testATransientFailureIsRetriedWithBackoffThenGivesUp() {
        var retry = TransientWriteRetry()
        XCTAssertEqual(
            retry.settle(report(failed: [xcode: "writeFailed(size,-25204)", figma: ReconcileFailure.frameMismatchKind])),
            0.5
        )
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 1.0)
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 2.0)
        XCTAssertNil(retry.settle(report(failed: [xcode: "timeout"])), "still hung after ~3.5 s: no loop")
    }

    func testASuccessfulWriteResetsTheBackoff() {
        var retry = TransientWriteRetry()
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 0.5)
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 1.0)
        XCTAssertNil(retry.settle(report(applied: [xcode])))
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 0.5)
    }

    func testTheSoonestDueWindowSetsTheDelay() {
        var retry = TransientWriteRetry()
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), 0.5)
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout", figma: "timeout"])), 0.5)
    }

    // MARK: - FX-07: retry under the overlay

    private let orbstack = WindowID(pid: 3, elementID: 1)
    private let target = CGRect(x: 986, y: 8, width: 888, height: 1114)

    /// Live 23:43:23: OrbStack, busy activating, failed its dispatched write
    /// (`readbackFailed(position/size,-25204)`); the overlay came down with
    /// its slot empty and the 0.5 s retry filled it 540 ms later. A window
    /// whose last dispatched write failed only because its app was busy is
    /// written again before the overlay comes down.
    func testAWindowWhoseLastWriteWasBusyIsRetriedBeforeTheHandOver() {
        let passes: [DispatchedOutcome] = [
            DispatchedOutcome(report: report(applied: [orbstack]), visible: [orbstack: target.offsetBy(dx: -100, dy: 0)]),
            DispatchedOutcome(
                report: report(failed: [orbstack: "readbackFailed(position/size,-25204)"]),
                visible: [orbstack: target, xcode: target]
            ),
        ]
        XCTAssertEqual(retryBeforeHandOver(passes), ParkingPlan(visible: [orbstack: target]))
    }

    func testALaterSuccessOrARefusalIsNotRetried() {
        let passes: [DispatchedOutcome] = [
            DispatchedOutcome(report: report(failed: [orbstack: "timeout"]), visible: [orbstack: target]),
            DispatchedOutcome(report: report(applied: [orbstack]), visible: [orbstack: target]),
            DispatchedOutcome(report: report(failed: [figma: ReconcileFailure.frameMismatchKind]), visible: [figma: target]),
        ]
        XCTAssertEqual(retryBeforeHandOver(passes), ParkingPlan())
    }

    func testAParkedTargetIsRetriedAsParked() {
        let parked = ParkedTarget(frame: CGRect(x: 1799, y: 8, width: 888, height: 1114), edge: .right, display: target)
        let passes = [
            DispatchedOutcome(report: report(failed: [orbstack: "timeout"]), visible: [:], parked: [orbstack: parked]),
        ]
        XCTAssertEqual(retryBeforeHandOver(passes), ParkingPlan(parked: [orbstack: parked]))
    }
}
