import XCTest
@testable import GioCore

/// FI-01: every reconcile failure is visible with id, app, kind and both
/// frames; the first occurrence per (window, kind) warns, repeats are debug.
final class ReconcileFailureTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    func testLineCarriesIdAppKindAndIntegerFrames() {
        let failure = ReconcileFailure(
            kind: "frameMismatch",
            requested: CGRect(x: 8.4, y: 8, width: 439.6, height: 784),
            actual: CGRect(x: 8, y: 8, width: 500, height: 784)
        )
        XCTAssertEqual(
            reconcileFailureLine(id: id(2), app: "WhatsApp", failure: failure),
            "reconcile failure id=10:2 app=WhatsApp kind=frameMismatch "
                + "requested=(8,8,440,784) actual=(8,8,500,784)"
        )
    }

    func testLineMarksMissingFramesAndDetail() {
        let failure = ReconcileFailure(kind: "other", requested: nil, actual: nil, detail: "unreadable")
        XCTAssertEqual(
            reconcileFailureLine(id: id(1), app: "pid10", failure: failure),
            "reconcile failure id=10:1 app=pid10 kind=other requested=none actual=none detail=unreadable"
        )
    }

    func testNonFiniteFramesNeverCrashFormatting() {
        let failure = ReconcileFailure(
            kind: "frameMismatch",
            requested: CGRect(x: CGFloat.nan, y: 0, width: CGFloat.infinity, height: 1),
            actual: nil
        )
        XCTAssertTrue(reconcileFailureLine(id: id(1), app: "A", failure: failure).contains("kind=frameMismatch"))
    }

    func testGateWarnsOncePerWindowAndKind() {
        var gate = FailureLogGate()
        XCTAssertEqual(gate.level(for: id(1), kind: "frameMismatch"), .warn)
        XCTAssertEqual(gate.level(for: id(1), kind: "frameMismatch"), .debug)
        XCTAssertEqual(gate.level(for: id(1), kind: "timeout"), .warn)
        XCTAssertEqual(gate.level(for: id(2), kind: "frameMismatch"), .warn)
        XCTAssertEqual(gate.level(for: id(2), kind: "frameMismatch"), .debug)
    }

    private struct Clamp: Error, FrameFailureReporting {
        let actual: CGRect
        var failureKind: String { "frameMismatch" }
        var failureActual: CGRect? { actual }
    }

    private final class FailingActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var clampedTo: [WindowID: CGRect] = [:]
        func frame(of id: WindowID) throws -> CGRect? { frames[id] }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            if let landed = clampedTo[id] {
                frames[id] = landed
                throw Clamp(actual: landed)
            }
            frames[id] = frame
        }
        func focus(id: WindowID) throws {}
    }

    func testReportCarriesStructuredFailure() {
        let actuator = FailingActuator()
        actuator.frames[id(1)] = CGRect(x: 0, y: 0, width: 100, height: 100)
        actuator.clampedTo[id(1)] = CGRect(x: 8, y: 8, width: 500, height: 784)
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let report = reconciler.reconcile(
            frames: [id(1): CGRect(x: 8, y: 8, width: 440, height: 784)], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failed, [id(1)])
        XCTAssertEqual(report.failures[id(1)], ReconcileFailure(
            kind: "frameMismatch",
            requested: CGRect(x: 8, y: 8, width: 440, height: 784),
            actual: CGRect(x: 8, y: 8, width: 500, height: 784)
        ))
    }

    func testReconcilerLogsWarnThenDebugWithAppName() {
        GioLog.clearForTests()
        GioLog.logFilePath = NSTemporaryDirectory() + "gio-fi01-\(UUID().uuidString).log"
        let actuator = FailingActuator()
        actuator.frames[id(1)] = CGRect(x: 0, y: 0, width: 100, height: 100)
        actuator.clampedTo[id(1)] = CGRect(x: 8, y: 8, width: 500, height: 784)
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .serial, appName: { _ in "WhatsApp" }
        )
        let target = [id(1): CGRect(x: 8, y: 8, width: 440, height: 784)]
        reconciler.reconcile(frames: target, focused: nil, currentlyFocused: nil)
        reconciler.reconcile(frames: target, focused: nil, currentlyFocused: nil)
        let lines = GioLog.entries().filter { $0.message.hasPrefix("reconcile failure") }
        XCTAssertEqual(lines.map(\.level), [.warn, .debug])
        XCTAssertEqual(
            lines.first?.message,
            "reconcile failure id=10:1 app=WhatsApp kind=frameMismatch "
                + "requested=(8,8,440,784) actual=(8,8,500,784)"
        )
        XCTAssertFalse(GioLog.entries().contains { $0.message.contains("see firstFailure") })
    }
}
