import CoreGraphics
import GioCore
import XCTest
@testable import GioSession

final class RenderVerifierTests: XCTestCase {
    private let id = WindowID(pid: 7, elementID: 1)
    private let target = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    private final class World: @unchecked Sendable {
        var shuttingDown = false
        var motion = false
        var flight = false
        var ready = true
        var visible: [WindowID: CGRect] = [:]
        var nudges: [[WindowID: [CGRect]]] = []
        var nudgeWrites = true
        var echoes: [(WindowID, CGRect)] = []
        /// TG-05: SkyLight usable, the repairs asked for and whether it moves.
        var windowServer = false
        var alignments: [[WindowID: CGRect]] = []
        var alignMoves = true
        var logs: [(LogLevel, String)] = []
    }

    private var world: World!
    private var probe: StubSystemProbe!
    private var scheduler: ManualScheduler!

    override func setUp() {
        world = World()
        world.visible = [id: target]
        probe = StubSystemProbe()
        probe.names[7] = "Editor"
        scheduler = ManualScheduler()
    }

    private func makeVerifier() -> RenderVerifier {
        let world = world!
        let probe = probe!
        let screen = screen
        return RenderVerifier(
            context: .init(
                isShuttingDown: { world.shuttingDown },
                isMotionActive: { world.motion },
                isFlightActive: { world.flight },
                isMouseDown: { probe.isMouseDown },
                isReady: { world.ready },
                visibleTargets: { world.visible },
                viewports: { [screen] },
                serverWindows: { probe.windowServerWindows(displayHeight: 1169) },
                nudge: { steps in
                    world.nudges.append(steps)
                    return world.nudgeWrites ? Array(steps.keys) : []
                },
                windowServerAvailable: { world.windowServer },
                alignWindowServer: { frames in
                    world.alignments.append(frames)
                    return world.alignMoves ? Set(frames.keys) : []
                },
                recordEcho: { id, frame, _ in world.echoes.append((id, frame)) },
                appName: { probe.applicationLabel($0) },
                log: { level, line in world.logs.append((level, line)) }
            ),
            scheduler: scheduler
        )
    }

    /// A settle that wrote `id` visibly at `target`, then the check scheduled.
    private func settle(_ verifier: RenderVerifier) {
        verifier.insertCandidate(id)
        verifier.recordSettled(from: [id: target])
        XCTAssertTrue(verifier.hasCandidates)
        verifier.schedule()
    }

    func testCheckRuns150msAfterTheSettleAndClearsCandidates() {
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target)]
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.149)
        XCTAssertEqual(probe.serverQueries, 0)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(probe.serverQueries, 1)
        XCTAssertFalse(verifier.hasCandidates)
        XCTAssertTrue(world.nudges.isEmpty, "a matching render needs no nudge")
    }

    func testNewMotionCancelsThePendingCheck() {
        let verifier = makeVerifier()
        settle(verifier)
        verifier.cancel()
        scheduler.advance(by: 1)
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testSkippedWhileMouseDownMotionFlightOrShutdown() {
        let verifier = makeVerifier()
        for block in [
            { self.probe.pressedMouseButtons = 1 }, { self.world.motion = true },
            { self.world.flight = true }, { self.world.shuttingDown = true },
        ] {
            probe.pressedMouseButtons = 0
            world.motion = false
            world.flight = false
            world.shuttingDown = false
            block()
            settle(verifier)
            scheduler.advance(by: 0.15)
        }
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testWithoutAReconcilerTheCheckWaitsAndKeepsCandidates() {
        world.ready = false
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(probe.serverQueries, 0)
        XCTAssertTrue(verifier.hasCandidates)
    }

    func testNothingVisibleWrittenSkipsTheWindowServerQuery() {
        world.visible = [:]
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testMismatchNudgesOnceAndRechecks100msLater() {
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(world.nudges.count, 1)
        XCTAssertEqual(world.nudges.first?[id], planNudge(target: target, viewport: screen))
        XCTAssertEqual(world.echoes.map(\.0), [id])
        XCTAssertEqual(world.logs.first?.0, .warn)
        XCTAssertTrue(world.logs.first?.1.hasPrefix("render mismatch id=7:1 app=Editor") == true)
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target)]
        scheduler.advance(by: 0.099)
        XCTAssertEqual(probe.serverQueries, 1)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(probe.serverQueries, 2)
        XCTAssertEqual(world.logs.last?.0, .info)
        XCTAssertEqual(world.logs.last?.1.hasSuffix("tier=position fixed=true"), true)
    }

    /// PF-C (live 2026-10-07: Tern stayed off the WindowServer list after the
    /// 1 pt move): a failed position nudge escalates to a size nudge.
    func testFailedPositionNudgeEscalatesToASizeNudge() {
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.25)
        XCTAssertEqual(world.nudges.count, 2)
        XCTAssertEqual(world.nudges.last?[id], planNudge(target: target, viewport: screen, tier: .size))
        XCTAssertEqual(world.echoes.map(\.0), [id, id])
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target)]
        scheduler.advance(by: 0.1)
        XCTAssertEqual(world.logs.last?.0, .info)
        XCTAssertEqual(world.logs.last?.1.hasSuffix("tier=size fixed=true"), true)
        XCTAssertTrue(world.logs.map(\.1).filter { $0.hasPrefix("render unverifiable") }.isEmpty)
    }

    func testFailedSizeNudgeMakesTheWindowUnverifiable() {
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.35)
        XCTAssertEqual(world.nudges.count, 2)
        XCTAssertEqual(world.logs.map(\.1).filter { $0.hasPrefix("render unverifiable") }.count, 1)
        let nudge = world.logs.last { $0.1.hasPrefix("render nudge") }
        XCTAssertEqual(nudge?.0, .warn)
        XCTAssertEqual(nudge?.1.hasSuffix("tier=size fixed=false"), true)
        // The next settle no longer checks it at all.
        settle(verifier)
        scheduler.advance(by: 0.35)
        XCTAssertEqual(probe.serverQueries, 3)
        XCTAssertEqual(world.nudges.count, 2)
        // Re-registered windows start clean.
        verifier.forget([id])
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(world.nudges.count, 3)
    }

    func testRecheckIsDroppedWhenANewPassSupersedesTheCheck() {
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        verifier.cancel()
        scheduler.advance(by: 0.1)
        XCTAssertEqual(probe.serverQueries, 1)
    }

    func testNoRecheckWhenTheNudgeWroteNothing() {
        world.nudgeWrites = false
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(probe.serverQueries, 1)
        XCTAssertTrue(world.echoes.isEmpty)
    }

    func testRepeatedMismatchWarnsOnceThenLogsAtDebug() {
        world.nudgeWrites = false
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        settle(verifier)
        scheduler.advance(by: 0.15)
        let levels = world.logs.filter { $0.1.hasPrefix("render mismatch") }.map(\.0)
        XCTAssertEqual(levels, [.warn, .debug])
    }

    func testSettledFramesOnlyRecordedForCandidates() {
        let verifier = makeVerifier()
        verifier.recordSettled(from: [id: target])
        verifier.insertCandidate(id)
        verifier.schedule()
        scheduler.advance(by: 0.15)
        XCTAssertEqual(probe.serverQueries, 0, "a frame settled before the window was a candidate is not checked")
    }

    // MARK: TG-05 SkyLight repair

    /// The log after a swipe: Code reported at its target, drawn 1832 pt to
    /// the left. SkyLight moves it to the frame the app reports before any
    /// Accessibility nudge.
    func testADrawnMismatchIsMovedThroughSkyLightToTheAppsFrameBeforeAnyNudge() {
        world.windowServer = true
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target.offsetBy(dx: -1832, dy: 0))]
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(world.alignments, [[id: target]])
        XCTAssertTrue(world.nudges.isEmpty, "no Accessibility nudge yet")
        XCTAssertEqual(world.echoes.map(\.0), [id])
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target)]
        scheduler.advance(by: 0.1)
        XCTAssertEqual(probe.serverQueries, 2)
        XCTAssertEqual(world.logs.last?.0, .info)
        XCTAssertEqual(world.logs.last?.1, "render repair id=7:1 app=Editor via=skylight fixed=true")
        scheduler.advance(by: 1)
        XCTAssertTrue(world.nudges.isEmpty)
    }

    /// A SkyLight repair that did not take falls back to the position nudge,
    /// then (PF-C) the size nudge, as before.
    func testAFailedSkyLightRepairFallsBackToTheNudges() {
        world.windowServer = true
        probe.serverWindows = [ServerWindow(pid: 7, bounds: target.offsetBy(dx: -33, dy: 0))]
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.25)
        let repair = world.logs.last { $0.1.hasPrefix("render repair") }
        XCTAssertEqual(repair?.0, .warn)
        XCTAssertEqual(repair?.1, "render repair id=7:1 app=Editor via=skylight fixed=false")
        XCTAssertEqual(world.nudges.count, 1)
        XCTAssertEqual(world.nudges.first?[id], planNudge(target: target, viewport: screen))
        scheduler.advance(by: 0.1)
        XCTAssertEqual(world.nudges.last?[id], planNudge(target: target, viewport: screen, tier: .size))
        scheduler.advance(by: 0.1)
        XCTAssertEqual(world.logs.map(\.1).filter { $0.hasPrefix("render unverifiable") }.count, 1)
        XCTAssertEqual(world.alignments.count, 1, "one SkyLight repair per window per settle")
    }

    /// Without SkyLight, or when it refuses the move, the mismatch is
    /// nudged at once, exactly as before TG-05.
    func testWithoutOrRefusedSkyLightTheMismatchIsNudgedAtOnce() {
        for refused in [false, true] {
            setUp()
            world.windowServer = refused
            world.alignMoves = false
            probe.serverWindows = [ServerWindow(pid: 7, bounds: target.offsetBy(dx: -33, dy: 0))]
            let verifier = makeVerifier()
            settle(verifier)
            scheduler.advance(by: 0.15)
            XCTAssertEqual(world.alignments.count, refused ? 1 : 0)
            XCTAssertEqual(world.nudges.first?[id], planNudge(target: target, viewport: screen))
            XCTAssertTrue(world.logs.map(\.1).filter { $0.hasPrefix("render repair") }.isEmpty)
        }
    }

    /// A window the WindowServer does not draw at all needs its app to
    /// paint: it goes straight to the nudge even with SkyLight.
    func testAMissingWindowIsNudgedEvenWithSkyLight() {
        world.windowServer = true
        let verifier = makeVerifier()
        settle(verifier)
        scheduler.advance(by: 0.15)
        XCTAssertTrue(world.alignments.isEmpty)
        XCTAssertEqual(world.nudges.count, 1)
    }
}
