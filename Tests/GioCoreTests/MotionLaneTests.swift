import XCTest
@testable import GioCore

/// PA-05: one persistent lane per app with a single latest-frame slot.
final class MotionLaneTests: XCTestCase {
    private let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func window(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func write(_ id: WindowID, _ from: CGFloat, _ to: CGFloat) -> MotionWrite {
        MotionWrite(id: id, from: start.offsetBy(dx: from, dy: 0), to: start.offsetBy(dx: to, dy: 0))
    }

    // MARK: Slot (pure)

    func testSlotOfferToEmptyDoesNotOverwrite() {
        var slot = MotionSlot()
        XCTAssertFalse(slot.offer([write(window(1), 0, 10)]))
        XCTAssertFalse(slot.isEmpty)
    }

    func testSlotLatestWinsKeepsTheOldestFromSoNoAttributeChangeIsLost() {
        var slot = MotionSlot()
        _ = slot.offer([write(window(1), 0, 10), write(window(2), 5, 15)])
        XCTAssertTrue(slot.offer([write(window(1), 10, 30)]))
        var taken: [MotionWrite] = []
        slot.take(into: &taken)
        XCTAssertEqual(taken, [write(window(1), 0, 30), write(window(2), 5, 15)])
        XCTAssertTrue(slot.isEmpty)
    }

    func testSlotAppendsWindowsItHasNotSeenAndDiscardEmptiesIt() {
        var slot = MotionSlot()
        _ = slot.offer([write(window(1), 0, 10)])
        XCTAssertTrue(slot.offer([write(window(2), 0, 10)]))
        XCTAssertEqual(slot.discard(), 2)
        XCTAssertTrue(slot.isEmpty)
        XCTAssertEqual(slot.discard(), 0)
    }

    // MARK: Lanes on the reconciler

    private final class Actuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var history: [WindowID: [CGRect]] = [:]
        private var frames: [WindowID: CGRect] = [:]
        var gate = false
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)

        func seed(_ id: WindowID, _ frame: CGRect) { lock.withLock { frames[id] = frame } }
        func written(_ id: WindowID) -> [CGRect] { lock.withLock { history[id] ?? [] } }
        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { frames[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }
        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            if gate {
                entered.signal()
                proceed.wait()
            }
            lock.withLock {
                frames[id] = frame
                history[id, default: []].append(frame)
            }
        }
        func focus(id: WindowID) throws {}
    }

    func testTheSameLaneServesEveryFrameAndReflow() {
        let actuator = Actuator()
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertNil(reconciler.motionLaneIdentity(pid: 10))
        var seen: [AnyObject] = []
        for step in 1...30 {
            XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, CGFloat(step - 1) * 3, CGFloat(step) * 3)]))
            reconciler.waitForMotionIdle(timeout: 2)
            seen.append(reconciler.motionLaneIdentity(pid: 10)!)
        }
        XCTAssertTrue(seen.allSatisfy { $0 === seen[0] })
        XCTAssertEqual(reconciler.motionLaneCount, 1)
        XCTAssertEqual(actuator.written(id).count, 30)
        XCTAssertTrue(reconciler.submitMotion(pid: 11, writes: [write(window(2, pid: 11), 0, 5)]))
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(reconciler.motionLaneCount, 2)
        XCTAssertTrue(reconciler.motionLaneIdentity(pid: 11) !== reconciler.motionLaneIdentity(pid: 10))
    }

    func testForgettingAnAppTearsItsLaneDownAndANewOneIsMadeOnDemand() {
        let actuator = Actuator()
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 0, 5)]))
        reconciler.waitForMotionIdle(timeout: 2)
        let first = reconciler.motionLaneIdentity(pid: 10)
        reconciler.forgetApp(pid: 10)
        XCTAssertNil(reconciler.motionLaneIdentity(pid: 10))
        XCTAssertEqual(reconciler.motionLaneCount, 0)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 5, 9)]))
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertNotNil(reconciler.motionLaneIdentity(pid: 10))
        XCTAssertTrue(reconciler.motionLaneIdentity(pid: 10) !== first)
    }

    func testForgettingABusyAppLetsItsInFlightWriteFinish() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 0, 5)]))
        actuator.entered.wait()
        reconciler.forgetApp(pid: 10)
        actuator.proceed.signal()
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(actuator.written(id), [start.offsetBy(dx: 5, dy: 0)])
        XCTAssertEqual(reconciler.motionLaneCount, 0)
    }

    func testAHungMotionWriteStillMakesTheFinalPassReportTimeoutAndDropsStaleFrames() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 0, 5)]))
        actuator.entered.wait()
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 5, 9)]))  // pending, stale after the final pass
        let report = reconciler.reconcile(
            frames: [id: start.offsetBy(dx: 100, dy: 0)], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failed, [id])
        XCTAssertEqual(report.failures[id]?.kind, "timeout")
        XCTAssertEqual(report.failureNotes[id], "timeout (previous write to this app still pending)")
        actuator.proceed.signal()
        reconciler.waitForMotionIdle(timeout: 2)
        // The stale pending frame was discarded when the wait timed out.
        XCTAssertEqual(actuator.written(id), [start.offsetBy(dx: 5, dy: 0)])
        XCTAssertGreaterThanOrEqual(reconciler.takeMotionStats()[10]?.drops ?? 0, 1)
    }

    func testFinalPassWaitsForTheInFlightMotionWriteThenWritesLast() {
        let actuator = Actuator()
        let id = window(1)
        actuator.seed(id, start)
        actuator.gate = true
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write(id, 0, 5)]))
        actuator.entered.wait()
        let final = start.offsetBy(dx: 100, dy: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            actuator.gate = false
            actuator.proceed.signal()
        }
        let report = reconciler.reconcile(frames: [id: final], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(report.applied, [id])
        XCTAssertEqual(actuator.written(id).last, final)
    }

    func testMotionIsRejectedWhileAnAbandonedReconcileLaneHoldsTheApp() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        let report = reconciler.reconcile(
            frames: [id: start.offsetBy(dx: 100, dy: 0)], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failures[id]?.kind, "timeout")
        XCTAssertFalse(reconciler.submitMotion(pid: 10, writes: [write(id, 0, 5)]))
        actuator.proceed.signal()
    }
}
