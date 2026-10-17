import XCTest
@testable import GioCore

/// PF-AQ: an instant pass asks for a snapshot settle run only when it
/// changed something the cache can see; a no-op pass (applied=0 parked=0,
/// e.g. each Chrome omnibox keystroke) starts no capture.
final class SettleCaptureGateTests: XCTestCase {
    private let window = WindowID(pid: 1, elementID: 1)
    private let shown: Set<WorkspaceID> = [WorkspaceID(1), WorkspaceID(2)]

    /// A gate that already saw `shown`, so only the pass itself decides.
    private func settledGate() -> SettleCaptureGate {
        var gate = SettleCaptureGate()
        _ = gate.decide(report: ReconcileReport(), placement: .instant(.startup), shown: shown)
        return gate
    }

    func testANoOpPassCapturesNothing() {
        var gate = settledGate()
        let report = ReconcileReport(alreadyCorrect: [window])
        XCTAssertNil(gate.decide(report: report, placement: .instant(nil), shown: shown))
        XCTAssertNil(gate.decide(report: ReconcileReport(), placement: .animate, shown: shown))
    }

    func testEveryWrittenOutcomeCaptures() {
        let reports = [
            ReconcileReport(applied: [window]),
            ReconcileReport(parked: [window]),
            ReconcileReport(failed: [window]),
            ReconcileReport(vanished: [window]),
            { var report = ReconcileReport(); report.deferred = [window]; return report }(),
        ]
        for report in reports {
            var gate = settledGate()
            XCTAssertEqual(gate.decide(report: report, placement: .instant(nil), shown: shown), .wrote, "\(report)")
        }
    }

    func testThePassThatEndsAnAXMotionCapturesOnce() {
        var gate = settledGate()
        gate.noteMotion()
        // The motion already moved the windows: the final pass finds them correct.
        XCTAssertEqual(gate.decide(report: ReconcileReport(alreadyCorrect: [window]), placement: .instant(nil), shown: shown), .motion)
        XCTAssertNil(gate.decide(report: ReconcileReport(alreadyCorrect: [window]), placement: .instant(nil), shown: shown))
    }

    func testAFlightSettleTakesOverTheMotionCapture() {
        var gate = settledGate()
        gate.noteMotion()
        gate.noteFlight(shown: shown)
        XCTAssertNil(gate.decide(report: ReconcileReport(), placement: .instant(nil), shown: shown))
    }

    func testEveryInstantPlacementReasonCaptures() {
        for reason in [InstantPlacementReason.startup, .permission, .mouse, .displays] {
            var gate = settledGate()
            XCTAssertEqual(gate.decide(report: ReconcileReport(), placement: .instant(reason), shown: shown), .placement)
        }
    }

    func testChangedShownWorkspacesCaptureForCoverage() {
        var gate = settledGate()
        let switched: Set<WorkspaceID> = [WorkspaceID(1), WorkspaceID(3)]
        XCTAssertEqual(gate.decide(report: ReconcileReport(), placement: .instant(nil), shown: switched), .shown)
        XCTAssertNil(gate.decide(report: ReconcileReport(), placement: .instant(nil), shown: switched))
    }

    func testAFlightRecordsTheShownWorkspaces() {
        var gate = settledGate()
        let switched: Set<WorkspaceID> = [WorkspaceID(3)]
        gate.noteFlight(shown: switched)
        XCTAssertNil(gate.decide(report: ReconcileReport(), placement: .instant(nil), shown: switched))
    }

    func testTheFirstPassCaptures() {
        var gate = SettleCaptureGate()
        XCTAssertEqual(gate.decide(report: ReconcileReport(), placement: .instant(nil), shown: shown), .shown)
    }

    func testTheLogLineNamesTheSkip() {
        XCTAssertEqual(settleCaptureSkippedLogLine, "snapshot settle skipped reason=noop")
    }
}
