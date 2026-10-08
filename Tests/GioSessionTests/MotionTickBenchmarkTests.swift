import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// Accepts every frame; no AX. Shared by the motion benchmarks and tests.
final class AcceptingMotionSink: MotionFrameSink {
    private(set) var submissions = 0
    var accepts = true
    var stats: [pid_t: MotionWriteStats] = [:]

    func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
        submissions += 1
        return accepts
    }

    func takeMotionStats() -> [pid_t: MotionWriteStats] {
        defer { stats = [:] }
        return stats
    }
}

/// Virtual clock for `MotionPlayer`, advanced by the test.
final class MotionClock: @unchecked Sendable {
    var now: TimeInterval = 0

    var read: ReflowClock {
        { [unowned self] in now }
    }
}

/// One motion tick with 10 flying windows, measured through the same work the
/// session does per tick (player sample + sink submissions, physical frames,
/// echo records, focus ring check). Debug build numbers: compare the two runs
/// of the same build, not across machines.
final class MotionTickBenchmarkTests: XCTestCase {
    static let windows = 10
    static let ticksPerIteration = 1000
    static let tickInterval: TimeInterval = 1.0 / 120

    /// Long flights so no iteration completes; ~8 pt per tick so every
    /// window is submitted each tick.
    static func animations() -> [WindowAnimation] {
        (0..<windows).map { index in
            let id = WindowID(pid: pid_t(index + 1), elementID: UInt64(index + 1))
            return WindowAnimation(
                id: id, from: CGRect(x: 0, y: CGFloat(index) * 50, width: 800, height: 600),
                to: CGRect(x: 1_000_000, y: CGFloat(index) * 50, width: 800, height: 600),
                duration: 1000, easing: .linear
            )
        }
    }

    /// Baseline: the tick body exactly as `SessionHost.motionTick` ran it
    /// before RF-07 (state inline in one class, no context closures).
    func testBaselineInlineHostTick() {
        let fixture = SessionFixture(frames: (0..<Self.windows).map { _ in .zero }, focus: 0)
        let clock = MotionClock()
        let harness = InlineHostTick(session: fixture.session, clock: clock)
        harness.player.start(Self.animations())
        measure {
            for _ in 0..<Self.ticksPerIteration {
                clock.now += Self.tickInterval
                harness.motionTick()
            }
        }
        XCTAssertTrue(harness.player.isActive)
        XCTAssertGreaterThan(harness.ringPublishes, 0)
    }
}

/// The pre-RF-07 host tick, reproduced with the same data structures.
private final class InlineHostTick {
    let player: MotionPlayer
    let sink = AcceptingMotionSink()
    var session: CommandSession
    let probe = StubSystemProbe()
    var physicalFrames: [WindowID: CGRect] = [:]
    var echoGate = WriteEchoGate()
    var reflowCoalescer = ReflowCoalescer()
    var isShuttingDown = false
    var ringPublishes = 0

    init(session: CommandSession, clock: MotionClock) {
        self.session = session
        player = MotionPlayer(sink: sink, clock: clock.read)
    }

    func motionTick() {
        guard player.isActive, !isShuttingDown else {
            return
        }
        if probe.isMouseDown {
            return
        }
        if reflowCoalescer.takeAtTick() {
            return
        }
        let tick = player.tick()
        let now = ProcessInfo.processInfo.systemUptime
        for (id, frame) in tick.sampled {
            physicalFrames[id] = frame
            echoGate.recordApplied(id, frame: frame, at: now)
        }
        if let focused = session.manager.currentWorkspace().focusedWindow, tick.sampled[focused] != nil {
            ringPublishes += 1
        }
    }
}
