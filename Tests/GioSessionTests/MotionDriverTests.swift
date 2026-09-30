import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// Host state the motion context reads and writes, plus a call log.
final class MotionWorld: @unchecked Sendable {
    var shuttingDown = false
    var mouseDown = false
    var coalesced = false
    var focused: WindowID?
    var physical: [WindowID: CGRect] = [:]
    var refreshes: [DisplayRefresh] = []
    var calls: [String] = []
    var sampled: [(WindowID, CGRect)] = []
    var prepositioned: [(WindowID, CGRect)] = []
    var unverified: [WindowID] = []
    var ringPublishes = 0
    var summaries: [MotionSummary] = []
    var logs: [(LogLevel, String)] = []

    func context(clock: MotionClock) -> MotionDriver.Context {
        .init(
            isShuttingDown: { self.shuttingDown },
            isMouseDown: { self.mouseDown },
            armInstantPlacementForMouse: { self.calls.append("armMouse") },
            reflowAll: { self.calls.append("reflowAll") },
            takeCoalescedReflow: {
                defer { self.coalesced = false }
                return self.coalesced
            },
            resetCoalescer: { self.calls.append("resetCoalescer") },
            performReflow: { self.calls.append("retarget") },
            finalPass: { self.calls.append("finalPass") },
            recordSampled: { id, frame, _ in
                self.sampled.append((id, frame))
                self.physical[id] = frame
            },
            recordPreposition: { id, frame, _ in self.prepositioned.append((id, frame)) },
            markUnverified: { self.unverified.append($0) },
            focusedWindow: { self.focused },
            publishFocusRing: { self.ringPublishes += 1 },
            learnResizeCapability: { self.summaries.append($0) },
            physicalFrame: { self.physical[$0] },
            displayRefreshes: { self.refreshes },
            playerAppName: { "App\($0)" },
            playerClock: clock.read,
            log: { self.logs.append(($0, $1)) },
            now: { clock.now }
        )
    }
}

final class MotionDriverTests: XCTestCase {
    private var world: MotionWorld!
    private var clock: MotionClock!
    private var scheduler: ManualScheduler!
    private var sink: AcceptingMotionSink!
    private var probeLogs: [(LogLevel, String)] = []
    private var driver: MotionDriver!

    private let a = WindowID(pid: 10, elementID: 1)
    private let b = WindowID(pid: 20, elementID: 2)

    override func setUp() {
        world = MotionWorld()
        clock = MotionClock()
        scheduler = ManualScheduler()
        sink = AcceptingMotionSink()
        let probes = ResizeProbeRunner(
            context: .init(
                isShuttingDown: { false }, matchWindows: { _ in [:] }, windowServerSize: { _ in nil },
                isSizeSettable: { _ in true }, appName: { "App\($0)" }, log: { _, _ in }
            ),
            scheduler: scheduler
        )
        driver = MotionDriver(context: world.context(clock: clock), resizeProbes: probes, scheduler: scheduler)
    }

    private func flight(_ id: WindowID, dx: CGFloat = 400, duration: Double = 0.3) -> WindowAnimation {
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        return WindowAnimation(id: id, from: from, to: from.offsetBy(dx: dx, dy: 0), duration: duration)
    }

    /// Advance virtual time for both the scheduler and the player's clock.
    private func advance(by delta: TimeInterval) {
        clock.now += delta
        scheduler.advance(by: delta)
    }

    // MARK: Start

    func testStartMarksWindowsUnverifiedAndAnimatingWithoutTickingYet() {
        driver.start([flight(a), flight(b)], sink: sink)

        XCTAssertTrue(driver.isActive)
        XCTAssertEqual(world.unverified, [a, b])
        XCTAssertEqual(driver.animatingPids, [10, 20])
        // Focus-now at motion start: the host raises the target right after
        // `start` returns, before the scheduler serves the first frame.
        XCTAssertEqual(sink.submissions, 0)
        XCTAssertTrue(world.sampled.isEmpty)

        scheduler.runPending()
        XCTAssertEqual(world.sampled.count, 2, "the first frame is served by the scheduler")
    }

    func testRetargetKeepsOneTimerAndOnePlayer() {
        let second = AcceptingMotionSink()
        driver.start([flight(a)], sink: sink)
        driver.start([flight(a, dx: 800)], sink: second)
        advance(by: 1.0 / 60)

        // One timer (two frames by now, not four) and the first sink only.
        XCTAssertEqual(world.sampled.count, 2)
        XCTAssertEqual(sink.submissions, 1)
        XCTAssertEqual(second.submissions, 0)
    }

    func testTimerIsPacedToTheDisplayHoldingTheWindows() {
        world.refreshes = [DisplayRefresh(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), framesPerSecond: 120)]
        driver.start([flight(a, duration: 10)], sink: sink)
        advance(by: 0.1)
        let at120 = world.sampled.count

        XCTAssertEqual(at120, 13, "t=0 plus 12 frames of 8.3 ms in 100 ms")
    }

    func testTimerDefaultsToSixtyHertz() {
        driver.start([flight(a, duration: 10)], sink: sink)
        advance(by: 0.1)

        XCTAssertEqual(world.sampled.count, 7, "t=0 plus 6 frames of 16.7 ms in 100 ms")
    }

    func testPrepositionsRecordOnlyWrittenWindows() {
        let frames = [a: CGRect(x: 0, y: 2000, width: 800, height: 600), b: CGRect(x: 900, y: 2000, width: 800, height: 600)]
        var asked: [WindowID: CGRect] = [:]
        driver.applyPrepositions(frames) { requested in
            asked = requested
            return [b]
        }

        XCTAssertEqual(asked, frames)
        XCTAssertEqual(world.prepositioned.map(\.0), [b])
        XCTAssertEqual(world.prepositioned.first?.1, frames[b])
    }

    // MARK: Tick

    func testMouseDownAbandonsTheMotionAndArmsInstantPlacement() {
        driver.start([flight(a)], sink: sink)
        world.mouseDown = true
        scheduler.runPending()

        XCTAssertFalse(driver.isActive)
        XCTAssertTrue(driver.animatingPids.isEmpty)
        XCTAssertEqual(world.calls, ["resetCoalescer", "armMouse", "reflowAll"])
        XCTAssertEqual(sink.submissions, 0, "nothing moves under the cursor")
        advance(by: 0.1)
        XCTAssertTrue(world.sampled.isEmpty, "the timer is gone")
    }

    func testCoalescedActionsRetargetInsteadOfSampling() {
        driver.start([flight(a)], sink: sink)
        world.coalesced = true
        scheduler.runPending()

        XCTAssertEqual(world.calls, ["retarget"])
        XCTAssertEqual(sink.submissions, 0)
        XCTAssertTrue(world.sampled.isEmpty)
        XCTAssertTrue(driver.isActive)

        advance(by: 1.0 / 60)
        XCTAssertEqual(world.sampled.count, 1, "the next tick samples again")
    }

    func testShutdownStopsOnTheNextTick() {
        driver.start([flight(a)], sink: sink)
        world.shuttingDown = true
        scheduler.runPending()

        XCTAssertFalse(driver.isActive)
        XCTAssertEqual(world.calls, ["resetCoalescer"])
        XCTAssertTrue(world.sampled.isEmpty)
    }

    func testRingPublishesOnlyWhenTheFocusedWindowIsInTheFlight() {
        world.focused = b
        driver.start([flight(a, duration: 10)], sink: sink)
        advance(by: 0.05)
        XCTAssertGreaterThan(world.sampled.count, 1)
        XCTAssertEqual(world.ringPublishes, 0)

        world.focused = a
        let before = world.sampled.count
        advance(by: 0.05)
        XCTAssertEqual(world.ringPublishes, world.sampled.count - before, "one publication per tick")
    }

    func testCompletionStopsLogsLearnsAndRunsTheFinalPass() {
        driver.start([flight(a, duration: 0.05)], sink: sink)
        advance(by: 0.1)

        XCTAssertFalse(driver.isActive)
        XCTAssertTrue(driver.animatingPids.isEmpty)
        XCTAssertEqual(world.summaries.count, 1)
        XCTAssertEqual(world.calls, ["resetCoalescer", "finalPass"])
        XCTAssertEqual(world.logs.filter { $0.1.hasPrefix("anim done") }.count, 1)
        XCTAssertEqual(world.physical[a], CGRect(x: 400, y: 0, width: 800, height: 600))
    }

    func testStopClearsAnimatingPidsAndResetsTheCoalescer() {
        driver.start([flight(a)], sink: sink)
        driver.stop()

        XCTAssertFalse(driver.isActive)
        XCTAssertTrue(driver.animatingPids.isEmpty)
        XCTAssertEqual(world.calls, ["resetCoalescer"])
        scheduler.runPending()
        XCTAssertEqual(sink.submissions, 0)
    }

    func testDisplayParametersPublishRefreshesAndCaptureScreensTogether() {
        let parameters = DisplayParameters()
        XCTAssertTrue(parameters.displayRefreshes.isEmpty)
        XCTAssertEqual(parameters.captureScreens.1, 1169)

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        parameters.store(
            refreshes: [DisplayRefresh(frame: screen, framesPerSecond: 120)],
            captureScreens: [SnapshotDisplay(id: 1, frame: screen, scale: 2)], primaryHeight: 982
        )

        XCTAssertEqual(parameters.displayRefreshes.map(\.framesPerSecond), [120])
        XCTAssertEqual(parameters.captureScreens.0.map(\.id), [1])
        XCTAssertEqual(parameters.captureScreens.1, 982)
    }

    // MARK: Benchmark

    /// Same load as `MotionTickBenchmarkTests.testBaselineInlineHostTick`,
    /// through the driver and its context closures.
    func testBenchmarkDriverTick() {
        let fixture = SessionFixture(
            frames: (0..<MotionTickBenchmarkTests.windows).map { _ in .zero }, focus: 0
        )
        let driver = MotionDriver(
            context: world.benchmarkContext(clock: clock) { fixture.session.manager.currentWorkspace().focusedWindow },
            resizeProbes: ResizeProbeRunner(
                context: .init(
                    isShuttingDown: { false }, matchWindows: { _ in [:] }, windowServerSize: { _ in nil },
                    isSizeSettable: { _ in true }, appName: { "App\($0)" }, log: { _, _ in }
                ),
                scheduler: scheduler
            ),
            scheduler: scheduler
        )
        driver.start(MotionTickBenchmarkTests.animations(), sink: sink)
        measure {
            for _ in 0..<MotionTickBenchmarkTests.ticksPerIteration {
                clock.now += MotionTickBenchmarkTests.tickInterval
                driver.tick()
            }
        }
        XCTAssertTrue(driver.isActive)
        XCTAssertGreaterThan(world.ringPublishes, 0)
    }
}

private extension MotionWorld {
    /// The live context's shape: in-place dictionary writes, no call log.
    func benchmarkContext(clock: MotionClock, focused: @escaping () -> WindowID?) -> MotionDriver.Context {
        var echo = WriteEchoGate()
        var coalescer = ReflowCoalescer()
        return .init(
            isShuttingDown: { self.shuttingDown },
            isMouseDown: { self.mouseDown },
            armInstantPlacementForMouse: {},
            reflowAll: {},
            takeCoalescedReflow: { coalescer.takeAtTick() },
            resetCoalescer: { coalescer.reset() },
            performReflow: {},
            finalPass: {},
            recordSampled: { id, frame, now in
                self.physical[id] = frame
                echo.recordApplied(id, frame: frame, at: now)
            },
            recordPreposition: { _, _, _ in },
            markUnverified: { _ in },
            focusedWindow: focused,
            publishFocusRing: { self.ringPublishes += 1 },
            learnResizeCapability: { _ in },
            physicalFrame: { self.physical[$0] },
            displayRefreshes: { [] },
            playerAppName: { _ in nil },
            playerClock: clock.read,
            log: { _, _ in },
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }
}
