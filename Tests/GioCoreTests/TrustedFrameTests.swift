import XCTest
@testable import GioCore

/// PA-04: frames Gio placed and verified are trusted, so the final exact pass
/// skips their AX read; any evidence that the window moved drops the trust.
final class TrustedFrameTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private let frame = CGRect(x: 100, y: 8, width: 700, height: 984)
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    // MARK: Decision table

    func testUntrustedWindowIsNeverSkipped() {
        XCTAssertFalse(TrustedFrames().canSkipRead(id(1), desired: frame))
    }

    func testTrustedEqualFrameIsSkipped() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        XCTAssertTrue(trusted.canSkipRead(id(1), desired: frame))
    }

    func testTrustedFrameWithinToleranceIsSkipped() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        XCTAssertTrue(trusted.canSkipRead(id(1), desired: frame.offsetBy(dx: 0.9, dy: -0.9)))
    }

    func testTrustedFrameBeyondToleranceIsRead() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame.offsetBy(dx: 1.5, dy: 0)))
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: CGRect(x: 100, y: 8, width: 702, height: 984)))
    }

    func testTrustIsPerWindow() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        XCTAssertFalse(trusted.canSkipRead(id(2), desired: frame))
    }

    func testInvalidateDropsTrust() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        trusted.invalidate(id(1))
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame))
    }

    func testInvalidateManyAndAll() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        trusted.trust(id(2), frame: frame)
        trusted.trust(id(3), frame: frame)
        trusted.invalidate([id(1), id(2)])
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame))
        XCTAssertFalse(trusted.canSkipRead(id(2), desired: frame))
        XCTAssertTrue(trusted.canSkipRead(id(3), desired: frame))
        trusted.removeAll()
        XCTAssertFalse(trusted.canSkipRead(id(3), desired: frame))
    }

    func testNewTrustReplacesTheOldFrame() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        let moved = frame.offsetBy(dx: 300, dy: 0)
        trusted.trust(id(1), frame: moved)
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame))
        XCTAssertTrue(trusted.canSkipRead(id(1), desired: moved))
    }

    // MARK: Trust after a settle

    func testSettleTrustsWrittenAndAlreadyCorrectWindows() {
        let parked = ParkedTarget(frame: CGRect(x: 1799, y: 8, width: 700, height: 984), edge: .right, display: display)
        let report = ReconcileReport(applied: [id(1)], alreadyCorrect: [id(2)], parked: [id(3)])
        var trusted = TrustedFrames()
        trusted.recordSettle(
            report: report,
            visible: [id(1): frame, id(2): frame.offsetBy(dx: 10, dy: 0)],
            parked: [id(3): parked]
        )
        XCTAssertTrue(trusted.canSkipRead(id(1), desired: frame))
        XCTAssertTrue(trusted.canSkipRead(id(2), desired: frame.offsetBy(dx: 10, dy: 0)))
        XCTAssertTrue(trusted.canSkipRead(id(3), desired: parked.frame))
    }

    func testSettleDropsFailedAndVanishedWindows() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        trusted.trust(id(2), frame: frame)
        trusted.recordSettle(
            report: ReconcileReport(vanished: [id(2)], failed: [id(1)]),
            visible: [id(1): frame, id(2): frame], parked: [:]
        )
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame))
        XCTAssertFalse(trusted.canSkipRead(id(2), desired: frame))
    }

    /// PF-A: a deferred window is still mid-motion; its follow-up pass must
    /// read it, never skip it on an old trusted frame.
    func testSettleDropsDeferredWindows() {
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        var report = ReconcileReport()
        report.deferred = [id(1)]
        trusted.recordSettle(report: report, visible: [id(1): frame], parked: [:])
        XCTAssertFalse(trusted.canSkipRead(id(1), desired: frame))
    }

    // MARK: Reconciler integration

    private final class CountingActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var reads = 0
        var sets: [(WindowID, CGRect)] = []

        func frame(of id: WindowID) throws -> CGRect? {
            reads += 1
            return frames[id]
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            sets.append((id, frame))
            frames[id] = frame
        }

        func focus(id: WindowID) throws {}
    }

    func testTrustedVisibleWindowSkipsTheAXRead() {
        let actuator = CountingActuator()
        actuator.frames = [id(1): frame]
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [id(1): frame], focused: nil, currentlyFocused: nil, trusted: trusted
        )
        XCTAssertEqual(actuator.reads, 0)
        XCTAssertTrue(actuator.sets.isEmpty)
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
        XCTAssertEqual(report.skippedReads, 1)
        XCTAssertEqual(report.settledFrames[id(1)], frame)
    }

    func testTrustedParkedWindowSkipsTheAXRead() {
        let actuator = CountingActuator()
        let parkedFrame = CGRect(x: 1799, y: 8, width: 700, height: 984)
        let park = ParkedTarget(frame: parkedFrame, edge: .right, display: display)
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: parkedFrame)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil, trusted: trusted
        )
        XCTAssertEqual(actuator.reads, 0)
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
        XCTAssertEqual(report.skippedReads, 1)
    }

    func testUntrustedWindowIsReadAndVerifiedAsBefore() {
        let actuator = CountingActuator()
        actuator.frames = [id(1): frame, id(2): frame.offsetBy(dx: 40, dy: 0)]
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [id(1): frame, id(2): frame], focused: nil, currentlyFocused: nil, trusted: trusted
        )
        XCTAssertEqual(actuator.reads, 1)
        XCTAssertEqual(report.skippedReads, 1)
        XCTAssertEqual(report.applied, [id(2)])
        XCTAssertEqual(report.settledFrames[id(2)], frame)
    }

    func testTrustedWindowWhoseTargetChangedIsReadAndWritten() {
        let actuator = CountingActuator()
        actuator.frames = [id(1): frame]
        var trusted = TrustedFrames()
        trusted.trust(id(1), frame: frame)
        let target = frame.offsetBy(dx: 400, dy: 0)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [id(1): target], focused: nil, currentlyFocused: nil, trusted: trusted
        )
        XCTAssertEqual(actuator.reads, 1)
        XCTAssertEqual(report.skippedReads, 0)
        XCTAssertEqual(report.applied, [id(1)])
    }

    func testReadWindowReportsTheFrameItWasFoundAt() {
        let actuator = CountingActuator()
        actuator.frames = [id(1): frame.offsetBy(dx: 0.4, dy: 0)]
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [id(1): frame], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
        XCTAssertEqual(report.settledFrames[id(1)], frame.offsetBy(dx: 0.4, dy: 0))
        XCTAssertEqual(report.skippedReads, 0)
    }

    func testDiagnosticsDoNotAffectReportEquality() {
        var lhs = ReconcileReport(alreadyCorrect: [id(1)])
        lhs.skippedReads = 3
        lhs.settledFrames = [id(1): frame]
        XCTAssertEqual(lhs, ReconcileReport(alreadyCorrect: [id(1)]))
    }
}
