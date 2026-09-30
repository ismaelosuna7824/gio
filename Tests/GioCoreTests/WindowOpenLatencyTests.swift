import CoreGraphics
import Foundation
@testable import GioCore
import XCTest

/// PF-02: the pure decisions that keep a window opening fast: no entry for a
/// window that lands on a hidden workspace (or follows there), entry writes
/// never wait for an in-flight motion, a quicker retry while only the frame
/// is unreadable, and the one-line timing record.
final class WindowOpenLatencyTests: XCTestCase {
    private let a = WindowID(pid: 7, elementID: 1)
    private let b = WindowID(pid: 8, elementID: 2)
    private let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

    // MARK: Arrival

    func testArrivalOnTheShownWorkspaceEnters() {
        XCTAssertEqual(planWindowOpenArrival(destinationShown: true, followed: false, minimized: false), .enter)
    }

    func testArrivalOnAHiddenWorkspaceIsOnlyPlaced() {
        XCTAssertEqual(planWindowOpenArrival(destinationShown: false, followed: false, minimized: false), .place)
    }

    func testFollowedArrivalRidesTheWorkspaceSwitchWithoutAnEntry() {
        // The destination is shown by the time the pass runs; still no entry.
        XCTAssertEqual(planWindowOpenArrival(destinationShown: true, followed: true, minimized: false), .followSwitch)
        XCTAssertEqual(planWindowOpenArrival(destinationShown: false, followed: true, minimized: false), .followSwitch)
    }

    func testMinimizedArrivalIsOnlyPlaced() {
        XCTAssertEqual(planWindowOpenArrival(destinationShown: true, followed: false, minimized: true), .place)
    }

    // MARK: Pre-position writes

    func testWithoutMotionEveryPrepositionIsWrittenAtOnce() {
        let plan = planPrepositionWrites([a: frame, b: frame], entries: [a], motionInFlight: false)
        XCTAssertEqual(plan.immediate, [a: frame, b: frame])
        XCTAssertTrue(plan.afterMotionIdle.isEmpty)
        XCTAssertFalse(plan.waitsForMotion)
    }

    func testEntryWritesNeverWaitForAnInFlightMotion() {
        let plan = planPrepositionWrites([a: frame], entries: [a], motionInFlight: true)
        XCTAssertEqual(plan.immediate, [a: frame], "the entry merges into the running motion")
        XCTAssertFalse(plan.waitsForMotion)
    }

    func testSwitchPrepositionsStillWaitWhileAMotionFlies() {
        let plan = planPrepositionWrites([a: frame, b: frame], entries: [a], motionInFlight: true)
        XCTAssertEqual(plan.immediate, [a: frame])
        XCTAssertEqual(plan.afterMotionIdle, [b: frame])
        XCTAssertTrue(plan.waitsForMotion)
    }

    // MARK: Registration retry

    func testUnreadableFrameRetriesSooner() {
        let delays = (0..<6).compactMap {
            WindowRegistrationRetry.delay(afterFailedAttempt: $0, reason: .frameUnreadable)
        }
        XCTAssertEqual(delays, [0.03, 0.08, 0.2, 0.5])
    }

    func testUnclassifiedElementKeepsTheOriginalSchedule() {
        let delays = (0..<6).compactMap {
            WindowRegistrationRetry.delay(afterFailedAttempt: $0, reason: .unclassified)
        }
        XCTAssertEqual(delays, [0.1, 0.3, 0.8])
        XCTAssertEqual(WindowRegistrationRetry.delay(afterFailedAttempt: 0), 0.1, "default reason: unclassified")
    }

    // MARK: Timeline

    private func timing(_ id: WindowID, registeredAt: TimeInterval = 1.040) -> WindowOpenTiming {
        WindowOpenTiming(
            id: id, app: "Firefox", createdAt: 1.000, registeredAt: registeredAt,
            retries: 1, workspace: "Web", follow: true
        )
    }

    func testTimelineLineCarriesEveryStageInMilliseconds() {
        var timeline = WindowOpenTimeline()
        timeline.registered(timing(a))
        timeline.wrote(at: 1.052, waitedForMotion: 0.003)
        let lines = timeline.settled(at: 1.400)
        XCTAssertEqual(lines, [
            "window open id=7:1 app=Firefox createdEvent→registered ms=40 registered→firstWrite ms=12"
                + " →settled ms=348 total ms=400 workspace=Web follow=true retries=1 waitedForMotion ms=3",
        ])
        XCTAssertTrue(timeline.settled(at: 2).isEmpty, "one line per window")
    }

    func testOnlyTheFirstWriteCounts() {
        var timeline = WindowOpenTimeline()
        timeline.registered(timing(a))
        timeline.wrote(at: 1.050, waitedForMotion: 0)
        timeline.wrote(at: 1.200, waitedForMotion: 0.3)
        let line = timeline.settled(at: 1.300).first ?? ""
        XCTAssertTrue(line.contains("registered→firstWrite ms=10 "), line)
        XCTAssertTrue(line.hasSuffix("waitedForMotion ms=0"), line)
    }

    func testAWindowNotYetWrittenIsNotSettled() {
        var timeline = WindowOpenTimeline()
        timeline.registered(timing(a))
        timeline.wrote(at: 1.050, waitedForMotion: 0)
        timeline.registered(timing(b, registeredAt: 1.100))
        XCTAssertEqual(timeline.settled(at: 1.300).count, 1)
        timeline.wrote(at: 1.310, waitedForMotion: 0)
        XCTAssertEqual(timeline.settled(at: 1.400).count, 1)
    }

    func testForgottenWindowLogsNothing() {
        var timeline = WindowOpenTimeline()
        timeline.registered(timing(a))
        timeline.forget(a)
        timeline.wrote(at: 1.050, waitedForMotion: 0)
        XCTAssertTrue(timeline.settled(at: 1.300).isEmpty)
    }

    func testTimelineIsBounded() {
        var timeline = WindowOpenTimeline()
        for index in 0..<100 {
            timeline.registered(timing(WindowID(pid: 1, elementID: UInt64(index))))
        }
        XCTAssertLessThanOrEqual(timeline.count, WindowOpenTimeline.capacity)
    }
}
