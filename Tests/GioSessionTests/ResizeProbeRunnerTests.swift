import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

final class ResizeProbeRunnerTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var enabled = true
        var shuttingDown = false
        /// Context closures called, `isEnabled` aside.
        var contextCalls = 0
        var matches: [WindowID: SnapshotMatch] = [:]
        var sizes: [UInt32: CGSize] = [:]
        var settable = true
        var matchQueries = 0
        var logs: [(LogLevel, String)] = []
    }

    private let id = WindowID(pid: 7, elementID: 3)
    private let from = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let to = CGRect(x: 0, y: 0, width: 1200, height: 900)
    private var world: World!
    private var scheduler: ManualScheduler!
    private var runner: ResizeProbeRunner!

    override func setUp() {
        world = World()
        scheduler = ManualScheduler()
        let world = world!
        let scheduler = scheduler!
        world.matches = [id: .matched(42)]
        world.sizes = [42: from.size]
        runner = ResizeProbeRunner(
            context: .init(
                isEnabled: { world.enabled },
                isShuttingDown: { world.shuttingDown },
                matchWindows: { _ in
                    world.matchQueries += 1
                    world.contextCalls += 1
                    return world.matches
                },
                windowServerSize: {
                    world.contextCalls += 1
                    return world.sizes[$0]
                },
                isSizeSettable: { _ in
                    world.contextCalls += 1
                    return world.settable
                },
                appName: { "App\($0)" },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            scheduler: scheduler
        )
    }

    private var growing: WindowAnimation {
        WindowAnimation(id: id, from: from, to: to, duration: 0.3)
    }

    private var latencyLines: [String] {
        world.logs.map(\.1).filter { $0.hasPrefix("resize latency") }
    }

    func testReachedSizeLogsLatencyOnceAndFirstOnlyTheFirstTime() {
        runner.probe(of: [growing], frames: \.from)
        XCTAssertEqual(runner.activeCount, 1)
        scheduler.advance(by: 0.035)
        world.sizes[42] = to.size
        scheduler.advance(by: 0.1)

        XCTAssertEqual(runner.activeCount, 0)
        XCTAssertEqual(latencyLines, ["resize latency id=7:3 app=App7 requestedSize=1200x900 wsMs=40 first=true"])

        world.sizes[42] = from.size
        runner.probe(of: [growing], frames: \.from)
        world.sizes[42] = to.size
        scheduler.advance(by: 0.1)
        XCTAssertEqual(latencyLines.last?.hasSuffix("first=false"), true)
    }

    /// PA-15d: without debug logging a growing motion arms no timer and
    /// queries nothing (no WindowServer match, no size, no AX attribute).
    func testDisabledRunnerStartsNoTimerAndCallsNothing() {
        world.enabled = false
        runner.probe(of: [growing], frames: \.from)
        XCTAssertEqual(runner.activeCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0, "no 8 ms timer")
        XCTAssertEqual(world.contextCalls, 0)
        scheduler.advance(by: 2)
        XCTAssertTrue(world.logs.isEmpty)

        world.enabled = true
        runner.probe(of: [growing], frames: \.from)
        XCTAssertEqual(runner.activeCount, 1, "debug logging turns it back on")
    }

    func testOnlyGrowingMatchedSettableWindowsNotAlreadyAtSizeAreProbed() {
        let shrinking = WindowAnimation(id: id, from: to, to: from, duration: 0.3)
        let instant = WindowAnimation(id: id, from: from, to: to, duration: 0)
        runner.probe(of: [shrinking, instant], frames: \.from)
        XCTAssertEqual(world.matchQueries, 0, "nothing growing: no WindowServer query")

        world.matches = [id: .ambiguous]
        runner.probe(of: [growing], frames: \.from)
        world.matches = [id: .matched(42)]
        world.settable = false
        runner.probe(of: [growing], frames: \.from)
        world.settable = true
        world.sizes[42] = to.size
        runner.probe(of: [growing], frames: \.from)

        XCTAssertEqual(runner.activeCount, 0)
    }

    func testLiveProbeOfTheSameSizeIsNotRestarted() {
        runner.probe(of: [growing], frames: \.from)
        scheduler.advance(by: 0.5)
        runner.probe(of: [growing], frames: \.from)
        world.sizes[42] = to.size
        scheduler.advance(by: 0.02)

        XCTAssertEqual(latencyLines.count, 1)
        XCTAssertTrue(latencyLines[0].contains("wsMs=504"), latencyLines[0])
    }

    func testWindowThatNeverResizesTimesOutQuietlyAndIsNotProbedAgainUntilForgotten() {
        runner.probe(of: [growing], frames: \.from)
        scheduler.advance(by: 1.6)

        XCTAssertEqual(runner.activeCount, 0)
        XCTAssertTrue(latencyLines.isEmpty)
        runner.probe(of: [growing], frames: \.from)
        XCTAssertEqual(runner.activeCount, 0)

        runner.forget(id)
        runner.probe(of: [growing], frames: \.from)
        XCTAssertEqual(runner.activeCount, 1)
    }

    func testSlowWindowThatMovedLogsTimeout() {
        runner.probe(of: [growing], frames: \.from)
        world.sizes[42] = CGSize(width: 1000, height: 700)
        scheduler.advance(by: 1.6)

        XCTAssertEqual(latencyLines.count, 1)
        XCTAssertTrue(latencyLines[0].contains("wsMs=timeout"))
    }

    func testShutdownSilencesThePoll() {
        runner.probe(of: [growing], frames: \.from)
        world.shuttingDown = true
        world.sizes[42] = to.size
        scheduler.advance(by: 0.1)

        XCTAssertTrue(latencyLines.isEmpty)
        XCTAssertEqual(runner.activeCount, 1)
    }
}
