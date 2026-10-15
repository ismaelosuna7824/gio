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

    func testATransientFailureIsRetriedOnceAndASuccessResetsIt() {
        var retry = TransientWriteRetry()
        XCTAssertEqual(
            retry.settle(report(failed: [xcode: "writeFailed(size,-25204)", figma: ReconcileFailure.frameMismatchKind])),
            [xcode]
        )
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), [], "the retry failed too: no loop")
        XCTAssertEqual(retry.settle(report(applied: [xcode])), [])
        XCTAssertEqual(retry.settle(report(failed: [xcode: "timeout"])), [xcode], "after a success it may retry again")
    }
}
