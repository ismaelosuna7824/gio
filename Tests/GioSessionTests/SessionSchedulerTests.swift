import Foundation
import XCTest
@testable import GioSession

final class ManualSchedulerTests: XCTestCase {
    func testAsyncRunsOnlyWhenDrainedInSubmissionOrder() {
        let scheduler = ManualScheduler()
        let log = Recorder<String>()
        scheduler.async { log.append("a") }
        scheduler.async { log.append("b") }
        XCTAssertEqual(log.values, [])
        scheduler.runPending()
        XCTAssertEqual(log.values, ["a", "b"])
    }

    func testDelayedWorkRunsAtItsDeadlineOrderedByTime() {
        let scheduler = ManualScheduler()
        let log = Recorder<String>()
        scheduler.asyncAfter(0.2) { log.append("late") }
        scheduler.asyncAfter(0.1) { log.append("early") }
        scheduler.advance(by: 0.09)
        XCTAssertEqual(log.values, [])
        scheduler.advance(by: 0.01)
        XCTAssertEqual(log.values, ["early"])
        scheduler.advance(by: 0.1)
        XCTAssertEqual(log.values, ["early", "late"])
        XCTAssertEqual(scheduler.now, 0.2, accuracy: 1e-9)
    }

    func testWorkScheduledWhileAdvancingRunsWhenDueInsideTheWindow() {
        let scheduler = ManualScheduler()
        let log = Recorder<String>()
        scheduler.asyncAfter(0.1) {
            log.append("first")
            scheduler.asyncAfter(0.1) { log.append("second") }
        }
        scheduler.advance(by: 0.15)
        XCTAssertEqual(log.values, ["first"])
        scheduler.advance(by: 0.05)
        XCTAssertEqual(log.values, ["first", "second"])
    }

    func testTimerRepeatsUntilCancelled() {
        let scheduler = ManualScheduler()
        let ticks = Recorder<Int>()
        let timer = scheduler.makeStrictTimer(start: 0, interval: 0.01) { ticks.append(1) }
        scheduler.advance(by: 0.035)
        XCTAssertEqual(ticks.count, 4) // 0, 10, 20, 30 ms
        timer.cancel()
        scheduler.advance(by: 0.1)
        XCTAssertEqual(ticks.count, 4)
    }

    func testTimerCancelledFromItsOwnHandlerStops() {
        let scheduler = ManualScheduler()
        let ticks = Recorder<Int>()
        let holder = TimerHolder()
        holder.timer = scheduler.makeStrictTimer(start: 0.01, interval: 0.01) {
            ticks.append(1)
            if ticks.count == 2 {
                holder.timer?.cancel()
            }
        }
        scheduler.advance(by: 1)
        XCTAssertEqual(ticks.count, 2)
    }

    func testPendingCountTracksQueuedWork() {
        let scheduler = ManualScheduler()
        scheduler.asyncAfter(1) {}
        scheduler.async {}
        XCTAssertEqual(scheduler.pendingCount, 2)
        scheduler.runPending()
        XCTAssertEqual(scheduler.pendingCount, 1)
    }
}

final class QueueSchedulerTests: XCTestCase {
    func testRunsWorkOnItsQueue() {
        let queue = DispatchQueue(label: "test.session")
        let scheduler = QueueScheduler(queue: queue)
        let done = expectation(description: "ran")
        scheduler.asyncAfter(0.01) {
            scheduler.assertOnQueue()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testCancelledTimerStopsFiring() {
        let queue = DispatchQueue(label: "test.session.timer")
        let scheduler = QueueScheduler(queue: queue)
        let fired = expectation(description: "fired")
        fired.assertForOverFulfill = false
        let ticks = Recorder<Int>()
        let timer = scheduler.makeStrictTimer(start: 0, interval: 0.005) {
            ticks.append(1)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
        let settled = queue.sync {
            timer.cancel()
            return ticks.count
        }
        let later = expectation(description: "later")
        queue.asyncAfter(deadline: .now() + 0.05) { later.fulfill() }
        wait(for: [later], timeout: 2)
        XCTAssertEqual(queue.sync { ticks.count }, settled)
    }
}

private final class TimerHolder: @unchecked Sendable {
    var timer: SessionTimer?
}
