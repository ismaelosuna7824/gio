import XCTest
@testable import GioCore

/// MO-03: each app's windows are written on their own lane, lanes overlap,
/// a hung app times out without blocking the others, and the report is the
/// same regardless of completion order.
final class WriteLaneTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let stale = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let target = CGRect(x: 100, y: 0, width: 400, height: 300)
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    // MARK: Lane planning (pure)

    func testLanesGroupByPidAndAreSortedByPid() {
        let lanes = planWriteLanes(
            frames: [
                id(3, pid: 20): target, id(1, pid: 10): target,
                id(2, pid: 20): target, id(4, pid: 10): target,
            ],
            parked: [:]
        )
        XCTAssertEqual(lanes.map(\.pid), [10, 20])
        XCTAssertEqual(lanes[0].items.map(\.id), [id(1, pid: 10), id(4, pid: 10)])
        XCTAssertEqual(lanes[1].items.map(\.id), [id(2, pid: 20), id(3, pid: 20)])
    }

    func testParkedWindowsLeadTheirLaneAndAreNotWrittenTwice() {
        let park = ParkedTarget(frame: target, edge: .right, display: display)
        let lanes = planWriteLanes(
            frames: [id(1, pid: 10): target, id(2, pid: 10): target],
            parked: [id(2, pid: 10): park, id(5, pid: 10): park]
        )
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lanes[0].items.map(\.id), [id(2, pid: 10), id(5, pid: 10), id(1, pid: 10)])
        XCTAssertEqual(lanes[0].items.map { $0.parked != nil }, [true, true, false])
    }

    func testItemIndicesFollowTheSerialOrder() {
        let park = ParkedTarget(frame: target, edge: .left, display: display)
        let lanes = planWriteLanes(
            frames: [id(1, pid: 20): target, id(1, pid: 10): target],
            parked: [id(9, pid: 20): park]
        )
        let byIndex = lanes.flatMap(\.items).sorted { $0.index < $1.index }.map(\.id)
        XCTAssertEqual(byIndex, [id(9, pid: 20), id(1, pid: 10), id(1, pid: 20)])
    }

    // MARK: Lane execution

    /// Thread-safe fake: sleeps per pid, can hang chosen windows until
    /// released, and logs the order of everything it is asked to do.
    private final class SlowActuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [WindowID: CGRect] = [:]
        private var log: [String] = []
        private var writeCounts: [pid_t: Int] = [:]
        var writeDelay: [pid_t: TimeInterval] = [:]
        /// Per-window write delay, overriding `writeDelay` (set before the pass starts).
        var windowDelay: [WindowID: TimeInterval] = [:]
        /// Each listed window blocks its first read until `release` is signalled.
        private var hangingIDs: Set<WindowID> = []
        var hanging: Set<WindowID> {
            get { lock.withLock { hangingIDs } }
            set { lock.withLock { hangingIDs = newValue } }
        }
        let release = DispatchSemaphore(value: 0)
        /// Writes to these windows throw (set before the pass starts).
        var failing: Set<WindowID> = []

        struct Refused: Error {}

        func current(_ id: WindowID) -> CGRect? {
            lock.withLock { frames[id] }
        }

        func seed(_ id: WindowID, _ frame: CGRect) {
            lock.withLock { frames[id] = frame }
        }

        var events: [String] { lock.withLock { log } }
        func writes(forPid pid: pid_t) -> Int { lock.withLock { writeCounts[pid, default: 0] } }

        func frame(of id: WindowID) throws -> CGRect? {
            if lock.withLock({ hangingIDs.remove(id) != nil }) {
                release.wait()
            }
            return lock.withLock { frames[id] }
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            Thread.sleep(forTimeInterval: windowDelay[id] ?? writeDelay[id.pid] ?? 0)
            if failing.contains(id) {
                lock.withLock { log.append("refuse \(id.pid):\(id.elementID)") }
                throw Refused()
            }
            lock.withLock {
                frames[id] = frame
                writeCounts[id.pid, default: 0] += 1
                log.append("set \(id.pid):\(id.elementID)")
            }
        }

        func focus(id: WindowID) throws {
            lock.withLock { log.append("focus \(id.pid):\(id.elementID)") }
        }
    }

    /// For apps that are slow but well under the stall: a 1 s stall keeps
    /// that margin on a loaded CI runner, where 0.25 s against a 0.15-0.2 s
    /// write timed lanes out. Tests of the stall itself keep 0.25 s.
    private func patientReconciler(_ actuator: SlowActuator) -> WindowReconciler<SlowActuator> {
        WindowReconciler(actuator: actuator, concurrency: .concurrent(stallTimeout: 1))
    }

    private func seeded(_ ids: [WindowID], delays: [pid_t: TimeInterval] = [:]) -> SlowActuator {
        let actuator = SlowActuator()
        actuator.writeDelay = delays
        for window in ids {
            actuator.seed(window, stale)
        }
        return actuator
    }

    func testLanesOverlapSoTotalTimeIsTheSlowestLaneNotTheSum() {
        let ids = [10, 20, 30, 40].flatMap { pid in [id(1, pid: pid_t(pid)), id(2, pid: pid_t(pid))] }
        let actuator = seeded(ids, delays: [10: 0.2, 20: 0.2, 30: 0.2, 40: 0.2])
        let reconciler = patientReconciler(actuator)
        let started = Date()
        let report = reconciler.reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        // Serial would take 8 x 200 ms = 1.6 s; four overlapping lanes ~400 ms.
        // The bound sits between them with room for a loaded runner.
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(report.applied, ids.sorted())
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testReportIsDeterministicWhateverTheCompletionOrder() {
        // pid 10 finishes last, pid 30 first; the report still lists sorted IDs.
        let ids = [id(1, pid: 10), id(1, pid: 20), id(1, pid: 30)]
        let actuator = seeded(ids, delays: [10: 0.12, 20: 0.06, 30: 0])
        let report = patientReconciler(actuator).reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.applied, ids)
        XCTAssertEqual(actuator.events.first, "set 30:1")
    }

    func testWindowsOfOneAppKeepParkedBeforeVisibleOrder() {
        let park = ParkedTarget(
            frame: CGRect(x: 1799, y: 0, width: 400, height: 300), edge: .right, display: display
        )
        let ids = [id(1, pid: 10), id(2, pid: 10), id(3, pid: 10)]
        let actuator = seeded(ids)
        let report = patientReconciler(actuator).reconcile(
            frames: [ids[0]: target, ids[1]: target], parked: [ids[2]: park],
            focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(actuator.events, ["set 10:3", "set 10:1", "set 10:2"])
        XCTAssertEqual(report.parked, [ids[2]])
        XCTAssertEqual(report.applied, [ids[0], ids[1]])
    }

    func testFocusIsWrittenAfterEveryLaneFinished() {
        let ids = [id(1, pid: 10), id(1, pid: 20), id(1, pid: 30)]
        let actuator = seeded(ids, delays: [10: 0.05, 20: 0.05, 30: 0.05])
        let report = patientReconciler(actuator).reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: ids[0], currentlyFocused: nil
        )
        XCTAssertTrue(report.focusChanged)
        XCTAssertEqual(actuator.events.last, "focus 10:1")
        XCTAssertEqual(actuator.events.count, 4)
    }

    func testHungAppTimesOutWithoutBlockingTheOthers() {
        let healthy = [id(1, pid: 10), id(1, pid: 20)]
        let hung = [id(1, pid: 30), id(2, pid: 30)]
        let actuator = seeded(healthy + hung)
        actuator.hanging = [hung[0]]
        defer { actuator.release.signal() }
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .concurrent(stallTimeout: 0.1)
        )
        let started = Date()
        let report = reconciler.reconcile(
            frames: Dictionary(uniqueKeysWithValues: (healthy + hung).map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(report.applied, healthy)
        XCTAssertEqual(report.failed, hung)
        XCTAssertEqual(report.failureNotes[hung[0]], "timeout")
        XCTAssertEqual(report.failureNotes[hung[1]], "timeout")
        XCTAssertNotNil(reconciler.lastTiming?.windows.first { $0.id == hung[0] })
    }

    func testWindowsFinishedBeforeTheStallKeepTheirResult() {
        let fine = id(1, pid: 30), stuck = id(2, pid: 30)
        let actuator = seeded([fine, stuck])
        actuator.hanging = [stuck]
        defer { actuator.release.signal() }
        let report = WindowReconciler(
            actuator: actuator, concurrency: .concurrent(stallTimeout: 0.1)
        ).reconcile(frames: [fine: target, stuck: target], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(report.applied, [fine])
        XCTAssertEqual(report.failed, [stuck])
    }

    func testAppStillHungFromAnEarlierReflowIsNotWrittenAgain() {
        let stuck = id(1, pid: 30), other = id(1, pid: 10)
        let actuator = seeded([stuck, other])
        actuator.hanging = [stuck]
        let reconciler = WindowReconciler(
            actuator: actuator, concurrency: .concurrent(stallTimeout: 0.1)
        )
        let frames = [stuck: target, other: target]
        _ = reconciler.reconcile(frames: frames, focused: nil, currentlyFocused: nil)
        let second = reconciler.reconcile(frames: frames, focused: nil, currentlyFocused: nil)
        XCTAssertEqual(second.failed, [stuck])
        XCTAssertTrue(second.failureNotes[stuck]?.hasPrefix("timeout") == true)
        XCTAssertEqual(second.alreadyCorrect, [other])
        actuator.release.signal()
        // Once the stuck call returns the app is writable again.
        let deadline = Date().addingTimeInterval(2)
        var third = second
        while Date() < deadline, third.failed == [stuck] {
            Thread.sleep(forTimeInterval: 0.02)
            third = reconciler.reconcile(frames: frames, focused: nil, currentlyFocused: nil)
        }
        XCTAssertTrue(third.failed.isEmpty)
    }

    // MARK: SM-12 dispatched passes (snapshot flights)

    func testADispatchedPassReturnsWithoutWaitingForASlowAppAndCollectSeesEveryOutcome() {
        let fast = id(1, pid: 10), slow = id(1, pid: 30)
        // Slow but under the stall timeout: collect waits for it.
        let actuator = seeded([fast, slow], delays: [30: 0.2])
        let reconciler = patientReconciler(actuator)
        let started = Date()
        let pass = reconciler.dispatch(frames: [fast: target, slow: target], focused: nil, currentlyFocused: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "the caller never waits for the slow app")
        XCTAssertFalse(pass.isFinished)
        let report = reconciler.collect(pass)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2, "collect waits for the lane")
        XCTAssertTrue(pass.isFinished)
        XCTAssertEqual(report.applied, [fast, slow])
        XCTAssertEqual(report.settledFrames[slow], target)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.deferred.isEmpty)
    }

    func testCollectStillSeesAFailedWriteOfASlowApp() {
        let fast = id(1, pid: 10), refusing = id(1, pid: 20)
        // Slow (longer than the dispatch's 0.1 s bound) but under the stall.
        let actuator = seeded([fast, refusing], delays: [20: 0.15])
        actuator.failing = [refusing]
        let reconciler = patientReconciler(actuator)
        let started = Date()
        let pass = reconciler.dispatch(frames: [fast: target, refusing: target], focused: nil, currentlyFocused: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        let report = reconciler.collect(pass)
        XCTAssertEqual(report.applied, [fast])
        XCTAssertEqual(report.failed, [refusing])
        XCTAssertNotNil(report.failureNotes[refusing])
        XCTAssertEqual(report.failures[refusing]?.requested, target)
        XCTAssertEqual(actuator.events.filter { $0.hasPrefix("refuse") }, ["refuse 20:1"])
    }

    func testDispatchedFocusRunsOnTheAppsLaneAfterTheWindowsOwnWrite() {
        let other = id(1, pid: 10), focused = id(1, pid: 30)
        let actuator = seeded([other, focused], delays: [30: 0.2])
        let reconciler = patientReconciler(actuator)
        let started = Date()
        let pass = reconciler.dispatch(
            frames: [other: target, focused: target], focused: focused, currentlyFocused: nil
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "the focus does not hold the caller either")
        let report = reconciler.collect(pass)
        XCTAssertTrue(report.focusChanged)
        XCTAssertFalse(report.focusFailed)
        let events = actuator.events
        XCTAssertEqual(events.last, "focus 30:1")
        XCTAssertLessThan(events.firstIndex(of: "set 30:1")!, events.firstIndex(of: "focus 30:1")!)
    }

    func testANewerDispatchSupersedesTheUnstartedWriteOfTheSameWindow() {
        let first = id(1, pid: 30), second = id(2, pid: 30)
        let newer = CGRect(x: 600, y: 0, width: 400, height: 300)
        let actuator = seeded([first, second], delays: [30: 0.15])
        let reconciler = patientReconciler(actuator)
        let older = reconciler.dispatch(frames: [first: target, second: target], focused: nil, currentlyFocused: nil)
        let latest = reconciler.dispatch(frames: [second: newer], focused: nil, currentlyFocused: nil)
        let olderReport = reconciler.collect(older)
        let latestReport = reconciler.collect(latest)
        XCTAssertEqual(actuator.events, ["set 30:1", "set 30:2"], "the stale target of window 2 is never written")
        XCTAssertEqual(actuator.current(second), newer)
        XCTAssertEqual(olderReport.applied, [first])
        XCTAssertTrue(olderReport.failed.isEmpty, "a superseded write is not a failure")
        XCTAssertEqual(latestReport.applied, [second])
    }

    func testAnOlderFocusNeverLandsAfterANewerOne() {
        let slow = id(1, pid: 30), fast = id(1, pid: 10)
        let actuator = seeded([slow, fast], delays: [30: 0.2])
        let reconciler = patientReconciler(actuator)
        let older = reconciler.dispatch(frames: [slow: target], focused: slow, currentlyFocused: nil)
        let latest = reconciler.dispatch(frames: [fast: target], focused: fast, currentlyFocused: nil)
        let olderReport = reconciler.collect(older)
        let latestReport = reconciler.collect(latest)
        XCTAssertEqual(actuator.events.filter { $0.hasPrefix("focus") }, ["focus 10:1"])
        XCTAssertFalse(olderReport.focusChanged)
        XCTAssertFalse(olderReport.focusFailed, "a superseded intent is not a failed focus")
        XCTAssertTrue(latestReport.focusChanged)
    }

    func testTheFocusOfASupersededWindowMovesBehindItsNewerWrite() {
        let first = id(1, pid: 30), focused = id(2, pid: 30)
        let newer = CGRect(x: 600, y: 0, width: 400, height: 300)
        let actuator = seeded([first, focused], delays: [30: 0.15])
        let reconciler = patientReconciler(actuator)
        let older = reconciler.dispatch(
            frames: [first: target, focused: target], focused: focused, currentlyFocused: nil
        )
        let latest = reconciler.dispatch(frames: [focused: newer], focused: nil, currentlyFocused: nil)
        _ = reconciler.collect(older)
        let latestReport = reconciler.collect(latest)
        XCTAssertEqual(actuator.events, ["set 30:1", "set 30:2", "focus 30:2"])
        XCTAssertTrue(latestReport.focusChanged)
    }

    func testADispatchedPassWaitsOnTheLaneForAMotionWriteInsteadOfDeferring() {
        let window = id(1, pid: 30)
        let actuator = seeded([window], delays: [30: 0.15])
        let reconciler = patientReconciler(actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 30, writes: [MotionWrite(id: window, from: stale, to: stale.offsetBy(dx: 50, dy: 0))]))
        let started = Date()
        let pass = reconciler.dispatch(frames: [window: target], focused: nil, currentlyFocused: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "no motion grace on the caller")
        let report = reconciler.collect(pass)
        XCTAssertTrue(report.deferred.isEmpty)
        XCTAssertEqual(report.applied, [window])
        XCTAssertEqual(actuator.current(window), target)
    }

    func testSerialModeRunsInGlobalSortedOrderOnTheCallingThread() {
        let ids = [id(1, pid: 20), id(1, pid: 10)]
        let actuator = seeded(ids)
        let report = WindowReconciler(actuator: actuator, concurrency: .serial).reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(actuator.events, ["set 10:1", "set 20:1"])
        XCTAssertEqual(report.applied, ids.sorted())
    }

    // MARK: SM-13 review fixes

    func testCollectRunsTheFocusOfAnAbandonedLaneExactlyOnce() {
        let other = id(1, pid: 10), focused = id(1, pid: 30)
        // Over the 0.25 s stall: collect abandons the focused app's lane.
        let actuator = seeded([other, focused], delays: [30: 0.4])
        let reconciler = WindowReconciler(actuator: actuator)
        let pass = reconciler.dispatch(
            frames: [other: target, focused: target], focused: focused, currentlyFocused: nil
        )
        let report = reconciler.collect(pass)
        XCTAssertEqual(actuator.events.filter { $0.hasPrefix("focus") }, ["focus 30:1"], "focus ran at collect")
        XCTAssertTrue(report.focusChanged)
        XCTAssertFalse(report.focusFailed)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            actuator.events.filter { $0.hasPrefix("focus") }, ["focus 30:1"], "the abandoned lane never focuses again"
        )
    }

    func testCollectRunsTheFocusWhenTheAppStayedBusyPastTheClaimWait() {
        let holder = id(2, pid: 30), focused = id(1, pid: 30)
        let actuator = seeded([holder, focused])
        actuator.windowDelay = [holder: 0.8]
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 30, writes: [MotionWrite(id: holder, from: stale, to: target)]))
        Thread.sleep(forTimeInterval: 0.02)
        let pass = reconciler.dispatch(frames: [focused: target], focused: focused, currentlyFocused: nil)
        let report = reconciler.collect(pass)
        XCTAssertEqual(report.failed, [focused], "the claim wait ran out: the window is reported")
        XCTAssertTrue(report.focusChanged, "the keyboard focus still moved")
        XCTAssertEqual(actuator.events.filter { $0.hasPrefix("focus") }, ["focus 30:1"])
    }

    func testCollectNeverRunsAnOlderFocusOverANewerOne() {
        let slow = id(1, pid: 30), fast = id(1, pid: 10)
        let actuator = seeded([slow, fast], delays: [30: 0.4])
        let reconciler = WindowReconciler(actuator: actuator)
        let older = reconciler.dispatch(frames: [slow: target], focused: slow, currentlyFocused: nil)
        let latest = reconciler.dispatch(frames: [fast: target], focused: fast, currentlyFocused: nil)
        let olderReport = reconciler.collect(older)
        let latestReport = reconciler.collect(latest)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(actuator.events.filter { $0.hasPrefix("focus") }, ["focus 10:1"])
        XCTAssertFalse(olderReport.focusChanged)
        XCTAssertTrue(latestReport.focusChanged)
    }

    func testADispatchedPassBoundsWhenEachWriteCanLand() {
        let first = id(1, pid: 30), second = id(2, pid: 30), other = id(1, pid: 10)
        let actuator = seeded([first, second, other])
        let reconciler = WindowReconciler(actuator: actuator)
        let pass = reconciler.dispatch(
            frames: [first: target, second: target, other: target], focused: nil, currentlyFocused: nil
        )
        // Claim wait (2 x 0.25 s) plus one stall per write up to and including its own.
        XCTAssertEqual(pass.landingBounds[first]!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(pass.landingBounds[second]!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(pass.landingBounds[other]!, 0.75, accuracy: 1e-9)
        _ = reconciler.collect(pass)
        let serial = WindowReconciler(actuator: actuator, concurrency: .serial)
        let done = serial.dispatch(frames: [first: target], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(done.landingBounds[first], 0, "a serial pass has written before dispatch returns")
        _ = serial.collect(done)
    }

    func testALaneWaitingForItsClaimIsNotAbandonedAndWritesWhenItWins() {
        let holder = id(2, pid: 30), window = id(1, pid: 30)
        let actuator = seeded([holder, window])
        // The motion write holds the app 0.4 s: past the 0.25 s stall, inside the 0.5 s claim wait.
        actuator.windowDelay = [holder: 0.4]
        let reconciler = WindowReconciler(actuator: actuator)
        XCTAssertTrue(reconciler.submitMotion(pid: 30, writes: [MotionWrite(id: holder, from: stale, to: target)]))
        Thread.sleep(forTimeInterval: 0.02)
        let pass = reconciler.dispatch(frames: [window: target], focused: nil, currentlyFocused: nil)
        let report = reconciler.collect(pass)
        XCTAssertEqual(report.applied, [window], "claim-wait time is not a stall")
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(actuator.current(window), target)
    }
}
