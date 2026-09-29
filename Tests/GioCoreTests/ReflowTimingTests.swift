import XCTest
@testable import GioCore

/// MO-01: every reflow reports total/per-window write time and AX call
/// counts, and names the slowest app. The clock is injected so the numbers
/// are deterministic; they run serially because one shared fake clock cannot
/// attribute time to overlapping lanes.
final class ReflowTimingTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

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

    /// Each write costs `writeCost[pid]` ms on the fake clock and 6 AX
    /// calls; each read costs 2 calls and no time.
    private final class TimedActuator: WindowActuator, @unchecked Sendable {
        let clock: FakeClock
        var writeCost: [pid_t: Double] = [:]
        var frames: [WindowID: CGRect] = [:]
        private var calls: [pid_t: Int] = [:]
        private let lock = NSLock()

        init(clock: FakeClock) {
            self.clock = clock
        }

        func axCallCount(forPid pid: pid_t) -> Int {
            lock.withLock { calls[pid, default: 0] }
        }

        private func count(_ pid: pid_t, _ n: Int) {
            lock.withLock { calls[pid, default: 0] += n }
        }

        func frame(of id: WindowID) throws -> CGRect? {
            count(id.pid, 2)
            return lock.withLock { frames[id] }
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            count(id.pid, 6)
            clock.advance(milliseconds: writeCost[id.pid, default: 0])
            lock.withLock { frames[id] = frame }
        }

        func focus(id: WindowID) throws {}
    }

    private let stale = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let target = CGRect(x: 100, y: 0, width: 400, height: 300)

    private func reconcile(
        _ actuator: TimedActuator, clock: FakeClock, ids: [WindowID]
    ) -> (WindowReconciler<TimedActuator>, ReconcileReport) {
        for window in ids {
            actuator.frames[window] = stale
        }
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .serial, clock: { clock.now() },
            appName: { $0 == 10 ? "Code" : ($0 == 20 ? "Safari" : nil) }
        )
        let report = reconciler.reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        return (reconciler, report)
    }

    override func setUp() {
        super.setUp()
        GioLog.clearForTests()
    }

    func testTimingRecordsPerWindowMillisecondsAndAxCalls() throws {
        let clock = FakeClock()
        let actuator = TimedActuator(clock: clock)
        actuator.writeCost = [10: 30, 20: 5]
        let a = id(1, pid: 10), b = id(2, pid: 20)
        let (reconciler, _) = reconcile(actuator, clock: clock, ids: [a, b])
        let timing = try XCTUnwrap(reconciler.lastTiming)
        XCTAssertEqual(timing.windows.map(\.id), [a, b])
        XCTAssertEqual(timing.windows[0].milliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(timing.windows[1].milliseconds, 5, accuracy: 0.001)
        XCTAssertEqual(timing.windows.map(\.axCalls), [8, 8])
        XCTAssertEqual(timing.windows.map(\.app), ["Code", "Safari"])
        XCTAssertEqual(timing.totalMilliseconds, 35, accuracy: 0.001)
        XCTAssertEqual(timing.axCalls, 16)
    }

    func testSlowestAppAggregatesWindowsOfTheSamePid() throws {
        let clock = FakeClock()
        let actuator = TimedActuator(clock: clock)
        actuator.writeCost = [10: 12, 20: 20]
        let ids = [id(1, pid: 10), id(2, pid: 10), id(3, pid: 20)]
        let (reconciler, _) = reconcile(actuator, clock: clock, ids: ids)
        let slowest = try XCTUnwrap(try XCTUnwrap(reconciler.lastTiming).slowestApp)
        XCTAssertEqual(slowest.app, "Code")
        XCTAssertEqual(slowest.milliseconds, 24, accuracy: 0.001)
    }

    func testUnknownAppFallsBackToPid() throws {
        let clock = FakeClock()
        let actuator = TimedActuator(clock: clock)
        actuator.writeCost = [77: 9]
        let (reconciler, _) = reconcile(actuator, clock: clock, ids: [id(1, pid: 77)])
        XCTAssertEqual(try XCTUnwrap(reconciler.lastTiming).windows.first?.app, "pid77")
    }

    func testSummaryLineIsLoggedAtInfo() {
        let clock = FakeClock()
        let actuator = TimedActuator(clock: clock)
        actuator.writeCost = [10: 30, 20: 5]
        _ = reconcile(actuator, clock: clock, ids: [id(1, pid: 10), id(2, pid: 20)])
        let infos = GioLog.entries(minLevel: .info).map(\.message)
        XCTAssertTrue(
            infos.contains { $0.hasPrefix("reflow timing total=35ms windows=2 axCalls=16 slowest=Code 30ms") },
            "\(infos)"
        )
    }

    func testOnlyWindowsOverTwentyMillisecondsAreLoggedAtDebug() {
        let clock = FakeClock()
        let actuator = TimedActuator(clock: clock)
        actuator.writeCost = [10: 30, 20: 5]
        _ = reconcile(actuator, clock: clock, ids: [id(1, pid: 10), id(2, pid: 20)])
        let slow = GioLog.entries(minLevel: .debug).filter { $0.message.hasPrefix("reflow slow") }
        XCTAssertEqual(slow.count, 1)
        XCTAssertEqual(slow.first?.level, .debug)
        XCTAssertTrue(slow.first?.message.contains("app=Code") == true)
        XCTAssertTrue(slow.first?.message.contains("30ms") == true)
    }

    func testEmptyReflowReportsNoSlowestApp() throws {
        let clock = FakeClock()
        let reconciler = WindowReconciler(
            actuator: TimedActuator(clock: clock), concurrency: .serial, clock: { clock.now() }
        )
        reconciler.reconcile(frames: [:], focused: nil, currentlyFocused: nil)
        let timing = try XCTUnwrap(reconciler.lastTiming)
        XCTAssertNil(timing.slowestApp)
        XCTAssertTrue(GioLog.entries(minLevel: .info).contains {
            $0.message.hasPrefix("reflow timing total=0ms windows=0 axCalls=0 slowest=none")
        })
    }
}
