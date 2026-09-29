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
        private var history: [WindowID: [CGRect]] = [:]
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
            Thread.sleep(forTimeInterval: delay)
            lock.withLock {
                frames[id] = frame
                history[id, default: []].append(frame)
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
        let stats = reconciler.takeMotionStats()
        XCTAssertEqual(stats.keys.sorted(), [10])
        XCTAssertEqual(stats[10]?.count, 1)
        XCTAssertTrue(reconciler.takeMotionStats().isEmpty)
    }

    func testBusyAppKeepsOnlyTheLatestPendingFrame() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        let first = start.offsetBy(dx: 10, dy: 0)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: id, from: start, to: first)]))
        actuator.entered.wait()
        // Accepted while the first write is in flight; the second overwrites
        // the first pending frame (latest wins) and inherits its `from`.
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: id, from: first, to: start.offsetBy(dx: 20, dy: 0))]))
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: id, from: start.offsetBy(dx: 20, dy: 0), to: start.offsetBy(dx: 30, dy: 0))]))
        XCTAssertTrue(reconciler.submitMotion(pid: 11, writes: [MotionWrite(id: window(2, pid: 11), from: start, to: start)]))
        actuator.proceed.signal()
        actuator.proceed.signal()
        actuator.proceed.signal()
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(actuator.written(id), [first, start.offsetBy(dx: 30, dy: 0)])
        XCTAssertEqual(actuator.verifies.count, 3)
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


    // MARK: - PA-03 aggregated stats and name lookups

    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 100
        func now() -> TimeInterval { lock.withLock { seconds } }
        func advance(milliseconds: Double) { lock.withLock { seconds += milliseconds / 1000 } }
    }

    private final class CostActuator: WindowActuator, @unchecked Sendable {
        let clock: StepClock
        var cost: [UInt64: Double] = [:]
        init(clock: StepClock) { self.clock = clock }
        func frame(of id: WindowID) throws -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {}
        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            clock.advance(milliseconds: cost[id.elementID, default: 0])
        }
        func focus(id: WindowID) throws {}
    }

    private final class NameProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func hit() { lock.withLock { calls += 1 } }
    }

    func testMotionTimingsAreAggregatedPerPidInPlace() {
        let clock = StepClock()
        let actuator = CostActuator(clock: clock)
        actuator.cost = [1: 3, 2: 9, 3: 4, 4: 7]
        let reconciler = WindowReconciler(actuator: actuator, clock: { clock.now() })
        for element in UInt64(1)...3 {
            let write = MotionWrite(id: window(element), from: start, to: start.offsetBy(dx: 10, dy: 0))
            XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
            reconciler.waitForMotionIdle(timeout: 2)
        }
        let other = MotionWrite(id: window(4, pid: 11), from: start, to: start.offsetBy(dx: 10, dy: 0))
        XCTAssertTrue(reconciler.submitMotion(pid: 11, writes: [other]))
        reconciler.waitForMotionIdle(timeout: 2)
        let stats = reconciler.takeMotionStats()
        XCTAssertEqual(stats.keys.sorted(), [10, 11])
        XCTAssertEqual(stats[10]?.count, 3)
        XCTAssertEqual(stats[10]?.maxMilliseconds ?? 0, 9, accuracy: 1e-6)
        XCTAssertEqual(stats[10]?.sumMilliseconds ?? 0, 16, accuracy: 1e-6)
        XCTAssertEqual(stats[11]?.count, 1)
        XCTAssertEqual(stats[11]?.maxMilliseconds ?? 0, 7, accuracy: 1e-6)
        XCTAssertTrue(reconciler.takeMotionStats().isEmpty)
    }

    func testOverwrittenPendingFramesAreCountedAsDropsForThatPid() {
        let actuator = Actuator()
        actuator.gate = true
        let id = window(1)
        actuator.seed(id, start)
        let reconciler = WindowReconciler(actuator: actuator)
        let write = MotionWrite(id: id, from: start, to: start.offsetBy(dx: 10, dy: 0))
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
        actuator.entered.wait()
        for _ in 0..<3 {
            XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
        }
        actuator.proceed.signal()
        actuator.proceed.signal()
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(reconciler.takeMotionStats()[10]?.drops, 2)
    }

    func testMotionWritesNeverResolveAppNames() {
        let actuator = Actuator()
        let id = window(1)
        actuator.seed(id, start)
        let probe = NameProbe()
        let reconciler = WindowReconciler(actuator: actuator, appName: { _ in probe.hit(); return "Term" })
        for step in 1...20 {
            let write = MotionWrite(id: id, from: start, to: start.offsetBy(dx: CGFloat(step) * 5, dy: 0))
            XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
            reconciler.waitForMotionIdle(timeout: 2)
        }
        XCTAssertEqual(probe.count, 0)
    }

    func testReconcileResolvesEachAppNameOnceNotPerWindow() {
        let actuator = Actuator()
        var frames: [WindowID: CGRect] = [:]
        for element in UInt64(1)...4 {
            actuator.seed(window(element), start)
            frames[window(element)] = start.offsetBy(dx: 50, dy: 0)
        }
        let probe = NameProbe()
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .serial, appName: { _ in probe.hit(); return "Term" }
        )
        reconciler.reconcile(frames: frames, focused: nil, currentlyFocused: nil)
        reconciler.reconcile(frames: frames.mapValues { $0.offsetBy(dx: 5, dy: 0) }, focused: nil, currentlyFocused: nil)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(reconciler.lastTiming?.windows.map(\.app), Array(repeating: "Term", count: 4))
    }

    func testTimingSkipsAXCallCountersWhenTheActuatorDoesNotTrackCalls() {
        final class Untracked: WindowActuator, @unchecked Sendable {
            private let lock = NSLock()
            private var reads = 0
            var countReads: Int { lock.withLock { reads } }
            var tracksCalls: Bool { false }
            func axCallCount(forPid pid: pid_t) -> Int { lock.withLock { reads += 1 }; return 0 }
            func frame(of id: WindowID) throws -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
            func setFrame(_ frame: CGRect, for id: WindowID) throws {}
            func focus(id: WindowID) throws {}
        }
        let actuator = Untracked()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        reconciler.reconcile(
            frames: [window(1): start.offsetBy(dx: 50, dy: 0)], focused: nil, currentlyFocused: nil
        )
        let write = MotionWrite(id: window(1), from: start, to: start.offsetBy(dx: 10, dy: 0))
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [write]))
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertEqual(actuator.countReads, 0)
    }
}
