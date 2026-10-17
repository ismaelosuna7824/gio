import XCTest
@testable import GioCore

/// PF-AM: `reflow timing` tells the truth. `focus=` is the focus call only,
/// the wait for an older focus is `focusWait=`, a step that never focused
/// reports 0 and does not stretch `total`, the line names its `path=`, and a
/// timed-out lane ends when it was abandoned, not when `collect` ran.
final class ReflowTimingFocusTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 100

        func now() -> TimeInterval {
            lock.withLock { seconds }
        }

        func advance(milliseconds: Double) {
            lock.withLock { seconds += milliseconds / 1000 }
        }
    }

    /// Focus costs `focusCost[id]` ms on the fake clock, after waiting on
    /// `gate` for ids in `blocking`; writes of `blockingWrites` wait on `writeGate`.
    private final class ClockActuator: WindowActuator, @unchecked Sendable {
        let clock: FakeClock
        var focusCost: [UInt64: Double] = [:]
        var blocking: Set<UInt64> = []
        var blockingWrites: Set<UInt64> = []
        let gate = DispatchSemaphore(value: 0)
        let writeGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var frames: [WindowID: CGRect] = [:]

        init(clock: FakeClock) {
            self.clock = clock
        }

        func frame(of id: WindowID) throws -> CGRect? {
            lock.withLock { frames[id] ?? .zero }
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            if blockingWrites.contains(id.elementID) {
                writeGate.wait()
            }
            lock.withLock { frames[id] = frame }
        }

        func focus(id: WindowID) throws {
            if blocking.contains(id.elementID) {
                gate.wait()
            }
            clock.advance(milliseconds: focusCost[id.elementID, default: 0])
        }
    }

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    override func setUp() {
        super.setUp()
        GioLog.clearForTests()
    }

    func testSummaryLineAppendsFocusWaitAndPath() {
        let timing = ReflowTiming(
            totalMilliseconds: 10, focusMilliseconds: 3, windows: [], focusAXCalls: 0,
            focusWaitMilliseconds: 4, path: .dispatch
        )
        XCTAssertEqual(
            timing.summaryLine,
            "reflow timing total=10ms windows=0 axCalls=0 slowest=none focus=3ms focusWait=4ms path=dispatch"
        )
        XCTAssertTrue(ReflowTiming(totalMilliseconds: 0, windows: []).summaryLine.hasSuffix("focusWait=0ms path=reconcile"))
    }

    func testAStaleStepReportsNoFocusTimeAndNoEnd() {
        let clock = FakeClock()
        let book = DispatchFocusBook()
        let step = DispatchFocusStep(target: id(1), generation: book.issue())
        _ = book.issue()
        step.run(book: book, clock: { clock.now() }) { _ in XCTFail("a stale step never focuses") }
        let outcome = step.outcome
        XCTAssertEqual(outcome.result, .stale)
        XCTAssertEqual(outcome.milliseconds, 0)
        XCTAssertNil(outcome.endedAt, "a step that never focused does not stretch total")
    }

    func testAStepMeasuresOnlyTheFocusCallAndReportsTheLockWaitApart() {
        let clock = FakeClock()
        let book = DispatchFocusBook()
        let generation = book.issue()
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // An older run holds `running` (the lock both share).
        DispatchQueue.global().async {
            _ = book.runIfLatest(generation) {
                holding.signal()
                release.wait()
            }
        }
        holding.wait()
        let step = DispatchFocusStep(target: id(1), generation: generation)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            step.run(book: book, clock: { clock.now() }) { _ in clock.advance(milliseconds: 20) }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        clock.advance(milliseconds: 50)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        let outcome = step.outcome
        XCTAssertEqual(outcome.result, .changed)
        XCTAssertEqual(outcome.milliseconds, 20, accuracy: 0.001)
        XCTAssertEqual(outcome.waitMilliseconds, 50, accuracy: 0.001)
    }

    func testReconcileReportsTheFocusIdleWaitAndItsPath() throws {
        let clock = FakeClock()
        let actuator = ClockActuator(clock: clock)
        actuator.blocking = [1]
        actuator.focusCost = [1: 40, 2: 10]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, clock: { clock.now() })
        reconciler.focusSoon(id(1))
        let gate = actuator.gate
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        reconciler.reconcile(frames: [:], focused: id(2), currentlyFocused: nil)
        let timing = try XCTUnwrap(reconciler.lastTiming)
        XCTAssertEqual(timing.path, .reconcile)
        XCTAssertEqual(timing.focusMilliseconds, 10, accuracy: 0.001)
        XCTAssertEqual(timing.focusWaitMilliseconds, 40, accuracy: 0.001)
        XCTAssertTrue(timing.summaryLine.hasSuffix("focus=10ms focusWait=40ms path=reconcile"), timing.summaryLine)
    }

    func testCollectReportsTheDispatchPathAndTheFocusCallOnly() throws {
        let clock = FakeClock()
        let actuator = ClockActuator(clock: clock)
        actuator.focusCost = [1: 15]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, clock: { clock.now() })
        let pass = reconciler.dispatch(frames: [:], focused: id(1), currentlyFocused: nil)
        reconciler.collect(pass)
        let timing = try XCTUnwrap(reconciler.lastTiming)
        XCTAssertEqual(timing.path, .dispatch)
        XCTAssertEqual(timing.focusMilliseconds, 15, accuracy: 0.001)
        XCTAssertEqual(timing.totalMilliseconds, 15, accuracy: 0.001)
    }

    func testATimedOutLaneEndsWhenItWasAbandonedNotWhenCollectRan() throws {
        let clock = FakeClock()
        let actuator = ClockActuator(clock: clock)
        actuator.blockingWrites = [1]
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .concurrent(stallTimeout: 0.05), clock: { clock.now() }
        )
        let pass = reconciler.dispatch(
            frames: [id(1): CGRect(x: 10, y: 0, width: 100, height: 100)], focused: nil, currentlyFocused: nil
        )
        // The flight runs long before the settle collects.
        clock.advance(milliseconds: 500)
        let report = reconciler.collect(pass)
        actuator.writeGate.signal()
        XCTAssertEqual(report.failed, [id(1)])
        let timing = try XCTUnwrap(reconciler.lastTiming)
        XCTAssertLessThan(timing.totalMilliseconds, 500, "the flight time is not the lane's time")
        XCTAssertEqual(timing.totalMilliseconds, 50, accuracy: 0.001)
    }
}
