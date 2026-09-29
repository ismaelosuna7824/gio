import XCTest
@testable import GioCore

/// MO-04 player: deterministic sampling on an injected clock, per-app frame
/// dropping, retargeting from mid-flight and the one-line summary.
final class MotionPlayerTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 0
        var reading: ReflowClock { { [self] in now } }
    }

    private final class FakeSink: MotionFrameSink {
        var busy: Set<pid_t> = []
        var accepted: [(pid: pid_t, writes: [MotionWrite])] = []
        var timings: [WindowWriteTiming] = []
        var idleWaits = 0

        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            guard !busy.contains(pid) else { return false }
            accepted.append((pid, writes))
            return true
        }

        func waitForMotionIdle(timeout: TimeInterval) { idleWaits += 1 }
        func takeMotionTimings() -> [WindowWriteTiming] { defer { timings = [] }; return timings }
    }

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func slide(
        _ window: WindowID, from: CGFloat = 0, to: CGFloat = 100, easing: AnimationEasing = .linear
    ) -> WindowAnimation {
        WindowAnimation(
            id: window, from: CGRect(x: from, y: 0, width: 50, height: 50),
            to: CGRect(x: to, y: 0, width: 50, height: 50), duration: 1, easing: easing
        )
    }

    private func makePlayer(_ clock: FakeClock, _ sink: FakeSink) -> MotionPlayer {
        MotionPlayer(sink: sink, clock: clock.reading, appName: { "app\($0)" })
    }

    func testSamplesStartMiddleAndEndWithEasing() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1), easing: .easeOut)])
        var tick = player.tick()
        XCTAssertEqual(tick.sampled[id(1)]?.origin.x, 0)
        XCTAssertNil(tick.summary)
        clock.now = 0.5
        tick = player.tick()
        XCTAssertEqual(tick.sampled[id(1)]?.origin.x ?? 0, 87.5, accuracy: 1e-9)
        clock.now = 1
        tick = player.tick()
        XCTAssertEqual(tick.sampled[id(1)]?.origin.x, 100)
        XCTAssertNotNil(tick.summary)
        XCTAssertFalse(player.isActive)
    }

    func testFrameWritesCarryTheLastSubmittedFrameAsFrom() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1))])
        clock.now = 0.25
        _ = player.tick()
        clock.now = 0.5
        _ = player.tick()
        XCTAssertEqual(sink.accepted.count, 2)
        XCTAssertEqual(sink.accepted[0].writes[0].from.origin.x, 0)
        XCTAssertEqual(sink.accepted[0].writes[0].to.origin.x, 25)
        XCTAssertEqual(sink.accepted[1].writes[0].from.origin.x, 25)
        XCTAssertEqual(sink.accepted[1].writes[0].to.origin.x, 50)
    }

    func testBusyAppDropsItsFrameButOthersStillMove() {
        let clock = FakeClock(), sink = FakeSink()
        let slow = id(1, pid: 20), fast = id(2, pid: 30)
        let player = makePlayer(clock, sink)
        player.start([slide(slow), slide(fast)])
        sink.busy = [20]
        clock.now = 0.25
        _ = player.tick()
        XCTAssertEqual(sink.accepted.map(\.pid), [30])
        sink.busy = []
        clock.now = 0.5
        _ = player.tick()
        // The dropped frame is never queued: the slow app resumes from the
        // last frame it really received (its start).
        let resumed = sink.accepted.last { $0.pid == 20 }!
        XCTAssertEqual(resumed.writes[0].from.origin.x, 0)
        XCTAssertEqual(resumed.writes[0].to.origin.x, 50)
        clock.now = 1
        let summary = player.tick().summary
        XCTAssertEqual(summary?.dropped, 1)
        XCTAssertEqual(summary?.frames, 3)
    }

    func testUnchangedSampleIsNotResubmitted() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1))])
        clock.now = 0.25
        _ = player.tick()
        _ = player.tick()
        XCTAssertEqual(sink.accepted.count, 1)
    }

    func testRetargetContinuesFromTheSampledFrameWithoutSnapping() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1), from: 0, to: 100)])
        clock.now = 0.5
        let mid = player.tick().sampled[id(1)]!
        player.start([slide(id(1), from: mid.origin.x, to: 0)])
        let restarted = player.tick().sampled[id(1)]!
        XCTAssertEqual(restarted.origin.x, mid.origin.x)
        XCTAssertTrue(player.isActive)
        clock.now = 1.0
        XCTAssertEqual(player.tick().sampled[id(1)]?.origin.x ?? 0, 25, accuracy: 1e-9)
        clock.now = 1.5
        let done = player.tick()
        XCTAssertEqual(done.sampled[id(1)]?.origin.x, 0)
        XCTAssertNotNil(done.summary)
        XCTAssertEqual(done.summary?.windows, 1)
    }

    func testRetargetKeepsCountingOneRunAndTracksSampledFrames() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1))])
        clock.now = 0.5
        _ = player.tick()
        XCTAssertEqual(player.sampledFrames[id(1)]?.origin.x, 50)
        player.start([slide(id(2))])
        clock.now = 1.5
        let summary = player.tick().summary
        XCTAssertEqual(summary?.windows, 2)
        XCTAssertEqual(summary?.frames, 2)
        XCTAssertEqual(summary?.duration ?? 0, 1.5, accuracy: 1e-9)
    }

    func testEmptyStartIsInactiveAndCancelDropsTheRun() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([])
        XCTAssertFalse(player.isActive)
        player.start([slide(id(1))])
        XCTAssertTrue(player.isActive)
        player.cancel()
        XCTAssertFalse(player.isActive)
        XCTAssertTrue(player.sampledFrames.isEmpty)
    }

    func testSummaryLineNamesSlowestAppByWorstSingleWrite() {
        let clock = FakeClock(), sink = FakeSink()
        let player = makePlayer(clock, sink)
        player.start([slide(id(1, pid: 20)), slide(id(2, pid: 30))])
        sink.timings = [
            WindowWriteTiming(id: id(1, pid: 20), app: "Slack", milliseconds: 41.6, axCalls: 1),
            WindowWriteTiming(id: id(1, pid: 20), app: "Slack", milliseconds: 3, axCalls: 1),
            WindowWriteTiming(id: id(2, pid: 30), app: "Xcode", milliseconds: 9, axCalls: 1),
        ]
        clock.now = 1
        let summary = player.tick().summary
        XCTAssertEqual(sink.idleWaits, 1)
        XCTAssertEqual(
            summary?.logLine,
            "anim done windows=2 frames=1 dropped=0 duration=1000ms slowest=Slack 42ms curve=ease-out"
        )
    }

    func testSummaryLineWithoutTimingsSaysNone() {
        let summary = MotionSummary(windows: 3, frames: 12, dropped: 2, duration: 0.2, slowest: nil)
        XCTAssertEqual(
            summary.logLine, "anim done windows=3 frames=12 dropped=2 duration=200ms slowest=none curve=ease-out"
        )
    }
}
