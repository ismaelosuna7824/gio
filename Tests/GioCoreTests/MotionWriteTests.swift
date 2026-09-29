import XCTest
@testable import GioCore

/// MO-04: motion frames go through the reconciler's per-app lane, never
/// queue behind a busy app, and never overlap a final reconcile.
final class MotionWriteTests: XCTestCase {
    private final class Actuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [WindowID: CGRect] = [:]
        private var verifyFlags: [Bool] = []
        var delay: TimeInterval = 0
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var gate = false

        func seed(_ id: WindowID, _ frame: CGRect) { lock.withLock { frames[id] = frame } }
        var verifies: [Bool] { lock.withLock { verifyFlags } }
        func current(_ id: WindowID) -> CGRect? { lock.withLock { frames[id] } }

        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { frames[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            if gate {
                entered.signal()
                proceed.wait()
            }
            Thread.sleep(forTimeInterval: delay)
            lock.withLock {
                frames[id] = frame
                verifyFlags.append(verify)
            }
        }

        func focus(id: WindowID) throws {}
    }

    private let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func window(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    func testMotionFrameIsWrittenWithoutVerifyAndTimed() {
        let actuator = Actuator()
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator, appName: { _ in "Term" })
        let target = start.offsetBy(dx: 40, dy: 0)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: id, from: start, to: target)]))
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(actuator.current(id), target)
        XCTAssertEqual(actuator.verifies, [false])
        let timings = reconciler.takeMotionTimings()
        XCTAssertEqual(timings.map(\.app), ["Term"])
        XCTAssertTrue(reconciler.takeMotionTimings().isEmpty)
    }

    func testBusyAppRejectsTheNextFrameInsteadOfQueueing() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        let write = MotionWrite(id: id, from: start, to: start.offsetBy(dx: 10, dy: 0))
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
        actuator.entered.wait()
        XCTAssertFalse(reconciler.submitMotion(pid: 10, writes: [write]))
        XCTAssertTrue(reconciler.submitMotion(pid: 11, writes: [MotionWrite(id: window(2, pid: 11), from: start, to: start)]))
        actuator.proceed.signal()
        actuator.proceed.signal()
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(actuator.verifies.count, 2)
    }

    func testReconcileWaitsForInFlightMotionInsteadOfSkippingTheApp() {
        let actuator = Actuator()
        actuator.delay = 0.05
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        let mid = start.offsetBy(dx: 30, dy: 0)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: id, from: start, to: mid)]))
        let final = start.offsetBy(dx: 100, dy: 0)
        let report = reconciler.reconcile(frames: [id: final], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(report.applied, [id])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(actuator.current(id), final)
    }
}
