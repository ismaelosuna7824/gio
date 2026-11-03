import CoreGraphics
import XCTest
@testable import GioCore

/// The session's physical frames after a settled pass. A window that kept
/// its own size (Terminal snaps to its character grid, live: requested
/// 744x933, actual 741x934) reports a mismatch with the frame it really
/// sits at; forgetting that frame left the focused Terminal without a ring
/// and dropped it as a neighbour of the others.
final class SettledPhysicalFramesTests: XCTestCase {
    private let terminal = WindowID(pid: 1, elementID: 5)
    private let browser = WindowID(pid: 2, elementID: 2)
    private let parkedWindow = WindowID(pid: 3, elementID: 1)

    private let requested = CGRect(x: 8, y: 8, width: 744, height: 933)
    private let landed = CGRect(x: 8, y: 7, width: 741, height: 934)

    func testMismatchKeepsWhereTheWindowLanded() {
        var frames: [WindowID: CGRect] = [:]
        let report = ReconcileReport(
            failed: [terminal],
            failures: [terminal: ReconcileFailure(kind: ReconcileFailure.frameMismatchKind, requested: requested, actual: landed)]
        )
        foldSettledPhysicalFrames(&frames, report: report, visible: [terminal: requested], parked: [:])
        XCTAssertEqual(frames[terminal], landed)
    }

    func testFailureWithoutAKnownFrameIsForgotten() {
        var frames = [terminal: requested]
        let report = ReconcileReport(
            failed: [terminal], failures: [terminal: ReconcileFailure(kind: "timeout", requested: requested)]
        )
        foldSettledPhysicalFrames(&frames, report: report, visible: [terminal: requested], parked: [:])
        XCTAssertNil(frames[terminal])
    }

    func testVanishedAndDeferredAreForgotten() {
        var frames = [terminal: requested, browser: requested]
        var report = ReconcileReport(vanished: [terminal])
        report.deferred = [browser]
        foldSettledPhysicalFrames(&frames, report: report, visible: [terminal: requested, browser: requested], parked: [:])
        XCTAssertTrue(frames.isEmpty)
    }

    func testWrittenWindowsSitAtTheirTargets() {
        var frames: [WindowID: CGRect] = [:]
        let slot = CGRect(x: 1511, y: 8, width: 744, height: 933)
        let target = ParkedTarget(frame: slot, edge: .right, display: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let report = ReconcileReport(applied: [browser], parked: [parkedWindow])
        foldSettledPhysicalFrames(
            &frames, report: report, visible: [browser: requested, parkedWindow: requested], parked: [parkedWindow: target]
        )
        XCTAssertEqual(frames, [browser: requested, parkedWindow: slot])
    }
}
