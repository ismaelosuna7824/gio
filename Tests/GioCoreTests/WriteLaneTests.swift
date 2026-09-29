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
        /// Each listed window blocks its first read until `release` is signalled.
        private var hangingIDs: Set<WindowID> = []
        var hanging: Set<WindowID> {
            get { lock.withLock { hangingIDs } }
            set { lock.withLock { hangingIDs = newValue } }
        }
        let release = DispatchSemaphore(value: 0)

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
            Thread.sleep(forTimeInterval: writeDelay[id.pid] ?? 0)
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
        let actuator = seeded(ids, delays: [10: 0.08, 20: 0.08, 30: 0.08, 40: 0.08])
        let reconciler = WindowReconciler(actuator: actuator)
        let started = Date()
        let report = reconciler.reconcile(
            frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, target) }),
            focused: nil, currentlyFocused: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        // Serial would take 8 x 80ms = 640ms; four overlapping lanes ~160ms.
        XCTAssertLessThan(elapsed, 0.45)
        XCTAssertEqual(report.applied, ids.sorted())
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testReportIsDeterministicWhateverTheCompletionOrder() {
        // pid 10 finishes last, pid 30 first; the report still lists sorted IDs.
        let ids = [id(1, pid: 10), id(1, pid: 20), id(1, pid: 30)]
        let actuator = seeded(ids, delays: [10: 0.12, 20: 0.06, 30: 0])
        let report = WindowReconciler(actuator: actuator).reconcile(
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
        let report = WindowReconciler(actuator: actuator).reconcile(
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
        let report = WindowReconciler(actuator: actuator).reconcile(
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
}
