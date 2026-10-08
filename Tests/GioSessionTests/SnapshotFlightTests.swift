import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// Records every call in order (`prime:N`, `fly:N`, `retarget:N`, `end`);
/// the tests append `writes`, `fallback` and `publish` to the same list.
final class FakeOverlay: OverlayPort, @unchecked Sendable {
    var events: [String] = []
    var begins: [(token: Int, flights: [OverlayFlight], holes: [WindowID: CGRect], decorations: OverlayDecorations)] = []
    var retargets: [(
        token: Int, targets: [WindowID: CGRect], adds: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    )] = []
    var flies: [Int] = []
    var ends = 0

    func beginFlight(
        token: Int, spring: SpringParameters, flights: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    ) {
        events.append("prime:\(token)")
        begins.append((token, flights, holes, decorations))
    }

    func flyFlight(token: Int) {
        events.append("fly:\(token)")
        flies.append(token)
    }

    func retargetFlight(
        token: Int, targets: [WindowID: CGRect], adds: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    ) {
        events.append("retarget:\(token)")
        retargets.append((token, targets, adds, holes, decorations))
    }

    func endFlight() {
        events.append("end")
        ends += 1
    }
}

final class SnapshotFlightTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var rendererAvailable = true
        var shuttingDown = false
        var coalesced = false
        var reflows = 0
        var renderChecks = 0
        var decorations = OverlayDecorations.none
        var captures: [SnapshotCaptureRequest] = []
        var completions: [@Sendable (SnapshotCaptureOutcome) -> Void] = []
        var logs: [(LogLevel, String)] = []
        /// Seconds the cache's clock advances on every read (0: none).
        var cacheDriftPerRead: TimeInterval = 0
        var cacheReads = 0
        /// SM-14: the paint checks asked for and their pending answers.
        var paintChecks: [[WindowID: CGRect]] = []
        var paintAnswers: [@Sendable ([WindowID: SnapshotPaintVerdict]) -> Void] = []
        /// SM-18: usable frames per display (nil: the display frames).
        var usableFrames: [CGRect]?
    }

    private let a = CGRect(x: 0, y: 100, width: 800, height: 900)
    private let b = CGRect(x: 820, y: 100, width: 800, height: 900)
    private var world: World!
    private var fixture: SessionFixture!
    private var scheduler: ManualScheduler!
    private var overlay: FakeOverlay!
    private var cache: SnapshotCacheRefresher!
    private var flight: SnapshotFlightController!
    private var idA: WindowID!
    private var idB: WindowID!

    override func setUp() {
        world = World()
        fixture = SessionFixture(frames: [a, b], focus: 0)
        scheduler = ManualScheduler()
        overlay = FakeOverlay()
        idA = SessionFixture.id(0, pid: 1)
        idB = SessionFixture.id(1, pid: 2)
        let world = world!
        let fixture = fixture!
        let scheduler = scheduler!
        let overlay = overlay!
        cache = SnapshotCacheRefresher(
            context: .init(
                session: { fixture.session },
                displays: { fixture.displays.allDisplays() },
                physicalFrame: { fixture.physicalFrames[$0] },
                isShuttingDown: { world.shuttingDown },
                isFlightActive: { [unowned self] in flight.isActive },
                isMotionActive: { false },
                rendererAvailable: { world.rendererAvailable },
                captureScreens: {
                    ([SnapshotDisplay(id: 1, frame: SessionFixture.screen, scale: 1)], SessionFixture.screen.height)
                },
                capture: { request, done in
                    world.captures.append(request)
                    world.completions.append(done)
                },
                prefetch: { _, _ in },
                log: { world.logs.append(($0, $1)) },
                physicalMemory: 64 << 30,
                now: {
                    if world.cacheDriftPerRead > 0 {
                        world.cacheReads += 1
                    }
                    return scheduler.now + Double(world.cacheReads) * world.cacheDriftPerRead
                }
            ),
            scheduler: scheduler
        )
        flight = SnapshotFlightController(
            context: .init(
                displayFrames: { fixture.displays.allDisplays().map(\.frame) },
                usableFrames: { world.usableFrames ?? fixture.displays.allDisplays().map(\.frame) },
                physicalFrames: { fixture.physicalFrames },
                isShuttingDown: { world.shuttingDown },
                takeCoalescedReflow: {
                    defer { world.coalesced = false }
                    return world.coalesced
                },
                requestReflow: { world.coalesced = true },
                performReflow: { world.reflows += 1 },
                decorations: { _ in world.decorations },
                publishIndicators: { overlay.events.append("publish") },
                collectWrites: { overlay.events.append("collect") },
                scheduleRenderCheck: { world.renderChecks += 1 },
                checkPaint: { frames, answer in
                    world.paintChecks.append(frames)
                    world.paintAnswers.append(answer)
                },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            cache: cache, overlay: overlay, scheduler: scheduler
        )
    }

    private func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Runs one refresh and completes its capture with `images` and, unless
    /// told otherwise, a backdrop for the one display.
    @discardableResult
    private func refresh(_ images: [WindowID: CGRect], backdrop: Bool = true) -> CGImage {
        cache.schedule()
        scheduler.advance(by: 0.3)
        let done = world.completions.removeLast()
        let backdropImage = image()
        done(SnapshotCaptureOutcome(
            images: images.mapValues { CapturedImage(image: image(), frame: $0) },
            backdrops: backdrop ? [CapturedBackdropImage(image: backdropImage, displayFrame: SessionFixture.screen)] : []
        ))
        scheduler.runPending()
        return backdropImage
    }

    private func slide(_ id: WindowID, from: CGRect, by dx: CGFloat) -> (WindowAnimation, ParkingPlan) {
        let to = from.offsetBy(dx: dx, dy: 0)
        var visible = fixture.physicalFrames
        visible[id] = to
        return (WindowAnimation(id: id, from: from, to: to, duration: 0.3), ParkingPlan(visible: visible))
    }

    /// Begins a flight, defers the pass like the host does, and reports the
    /// prime: the controller then runs the writes and flies.
    private func beginAndPrime() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()
    }

    private func deferPass() {
        let overlay = overlay!
        let flight = flight!
        flight.deferPass(
            writes: {
                overlay.events.append("writes")
                flight.passSettled()
            },
            fallback: { overlay.events.append("fallback") }
        )
    }

    // MARK: Order: prime, writes, fly

    func testRealWindowsAreWrittenOnlyAfterTheOverlayIsPrimedAndThenTheLayersFly() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)

        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        XCTAssertTrue(flight.isActive)
        XCTAssertEqual(overlay.events, ["prime:1"])
        XCTAssertEqual(overlay.begins.first?.flights.first?.items.map(\.id).sorted(), [idA, idB])
        deferPass()
        XCTAssertEqual(overlay.events, ["prime:1"], "nothing is written before the prime is reported")

        flight.primed(1, ok: true)
        XCTAssertEqual(overlay.events, ["prime:1"], "the prime report hops onto the session queue")
        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1", "writes", "fly:1"])
        XCTAssertTrue(flight.isActive, "the layers have not landed yet")
        XCTAssertEqual(overlay.ends, 0)

        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(
            overlay.events.suffix(3), ["collect", "publish", "end"],
            "the dispatched writes are folded, then ring and dim, then the overlay goes"
        )
        XCTAssertEqual(world.renderChecks, 1)
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("snapshot flight layers=2") })
        XCTAssertEqual(scheduler.pendingCount, 1, "one cache refresh after the settle")
    }

    func testPrimingFailureFallsBackToAXBeforeAnyWrite() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()

        flight.primed(1, ok: false)
        scheduler.runPending()

        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.events, ["prime:1", "end", "fallback", "publish"], "no panel left, no write, AX motion, ring back")
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot fallback reason=prime-failed ids=2" })
        XCTAssertEqual(overlay.flies, [])
        // A late layersFinished for the dead flight settles nothing.
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertEqual(overlay.ends, 1)
    }

    func testAStalePrimeReportIsIgnored() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(7, ok: true)
        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1"])
        XCTAssertTrue(flight.isActive)
    }

    func testARetargetWhilePrimingSupersedesThePendingWrites() {
        refresh([idA: a, idB: b])
        let (first, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [first], plans: [plan], spring: .niri), .priming)
        deferPass()
        let (second, plan2) = slide(idA, from: a, by: 200)

        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .priming)
        let overlay = overlay!
        flight.deferPass(writes: { overlay.events.append("writes-2") }, fallback: { overlay.events.append("fallback-2") })
        XCTAssertEqual(overlay.events, ["prime:1", "retarget:2"])
        XCTAssertEqual(overlay.retargets.first?.targets[idA], second.to)

        flight.primed(1, ok: true)
        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1", "retarget:2", "writes-2", "fly:2"], "only the latest pass writes")
    }

    /// A key press during the prime leaves a coalesced request behind; the
    /// deferred writes (the host's instant pass stops the AX motion, which
    /// resets the coalescer) must not swallow it: the flight retargets to
    /// the newest layout shortly after the fly.
    func testACoalescedReflowSurvivesTheDeferredWrites() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        let overlay = overlay!
        let world = world!
        flight.deferPass(
            writes: {
                overlay.events.append("writes")
                world.coalesced = false
            },
            fallback: { overlay.events.append("fallback") }
        )
        // The press arrived while priming: request coalesced, retarget scheduled.
        world.coalesced = true
        flight.scheduleReflow()

        flight.primed(1, ok: true)
        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1", "writes", "fly:1"])
        XCTAssertTrue(world.coalesced, "the request is put back after the writes")
        scheduler.advance(by: SnapshotFlightController.retargetDelay)
        XCTAssertEqual(world.reflows, 1, "the merged retarget runs on the newest layout")
        XCTAssertFalse(world.coalesced)
    }

    func testNoCoalescedReflowSchedulesNothingAfterThePrime() {
        beginAndPrime()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(world.reflows, 0)
    }

    func testAbortWhilePrimingRunsTheFallbackInsteadOfTheWrites() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()

        flight.aborted(.mouseDown)
        scheduler.runPending()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(
            overlay.events, ["prime:1", "collect", "publish", "fallback"],
            "the overlay came down itself; the pass still happens"
        )
        XCTAssertTrue(world.logs.contains { $0.1 == snapshotAbortLine(reason: .mouseDown) })
        flight.primed(1, ok: true)
        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1", "collect", "publish", "fallback"], "a late prime report changes nothing")
    }

    // MARK: Backdrop and decorations

    func testTheBackdropComesFromTheCache() {
        let backdrop = refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        XCTAssertTrue(overlay.begins.first?.flights.first?.backdrop === backdrop)
        XCTAssertEqual(overlay.begins.first?.flights.first?.displayFrame, SessionFixture.screen)
        XCTAssertEqual(overlay.begins.first?.flights.first?.usableFrame, SessionFixture.screen, "full-frame display")
    }

    func testEachFlightCarriesItsDisplaysUsableFrame() {
        // SM-18: menu bar on top, Dock at the bottom; the panel covers only this.
        let usable = CGRect(x: 0, y: 70, width: SessionFixture.screen.width, height: SessionFixture.screen.height - 107)
        world.usableFrames = [usable]
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        XCTAssertEqual(overlay.begins.first?.flights.first?.displayFrame, SessionFixture.screen)
        XCTAssertEqual(overlay.begins.first?.flights.first?.usableFrame, usable)
    }

    func testMissingBackdropFallsBackOnlyWhenTheCacheHasNone() {
        refresh([idA: a, idB: b], backdrop: false)
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .ax)
        XCTAssertTrue(overlay.events.isEmpty)
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot fallback reason=no-backdrop ids=0" })
    }

    func testDecorationsReachTheOverlayAtBeginAndRetarget() {
        let ring = OverlayDecorations(ring: OverlayRing(id: idA, width: 4, color: FocusRingSectionConfig.defaultColor), dim: nil)
        world.decorations = ring
        beginAndPrime()
        XCTAssertEqual(overlay.begins.first?.decorations, ring)
        let dim = OverlayDecorations(ring: nil, dim: OverlayDim(ids: [idB], strength: 0.2))
        world.decorations = dim
        let (second, plan2) = slide(idA, from: a.offsetBy(dx: 100, dy: 0), by: 100)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        XCTAssertEqual(overlay.retargets.first?.decorations, dim)
    }

    // MARK: Flight

    func testStaleTokenDoesNotSettle() {
        beginAndPrime()
        flight.layersFinished(7)
        scheduler.runPending()
        XCTAssertTrue(flight.isActive)
    }

    func testAbortFromTheOverlayClearsAndRefreshes() {
        beginAndPrime()

        flight.aborted(.mouseDown)
        XCTAssertTrue(flight.isActive, "the abort hops onto the session queue")
        scheduler.runPending()

        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, 0, "the overlay already came down itself")
        XCTAssertEqual(overlay.events.last, "publish")
        XCTAssertEqual(world.renderChecks, 1)
        XCTAssertTrue(world.logs.contains { $0.1 == snapshotAbortLine(reason: .mouseDown) })
        // The old token is dead: late layers do not settle anything.
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertEqual(overlay.ends, 0)
    }

    func testEndAndDisplayChangeBringTheOverlayDown() {
        beginAndPrime()
        flight.abortForDisplayChange()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, 1)
        XCTAssertEqual(overlay.events.suffix(3), ["collect", "end", "publish"], "the writes are folded before anything else runs")
        XCTAssertTrue(world.logs.contains { $0.1 == snapshotAbortLine(reason: .displayChange) })
        flight.end()
        XCTAssertEqual(overlay.ends, 1, "nothing to end without a flight")
    }

    // MARK: SM-12 dispatched writes and measured frames

    func testEveryExitFoldsTheDispatchedWritesOnce() {
        beginAndPrime()
        flight.aborted(.watchdog)
        scheduler.runPending()
        XCTAssertEqual(overlay.events.filter { $0 == "collect" }.count, 1, "watchdog / mouse down")

        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        flight.end()
        XCTAssertEqual(overlay.events.filter { $0 == "collect" }.count, 2, "end (shutdown, a non-animated pass)")
        flight.end()
        flight.aborted(.mouseDown)
        scheduler.runPending()
        XCTAssertEqual(overlay.events.filter { $0 == "collect" }.count, 2, "nothing to fold without a flight")
    }

    func testAPrimeFailureHasNoWritesToFold() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(1, ok: false)
        scheduler.runPending()
        XCTAssertFalse(overlay.events.contains("collect"))
    }

    func testSettleReportsTheFramesTheDisplayPresented() {
        beginAndPrime()
        scheduler.advance(by: 0.4)
        flight.layersFinished(1, frames: FlightFrameStats(presented: 40, expected: 43, hitches: 2, duration: 0.36))
        scheduler.runPending()
        let lines = world.logs.map(\.1)
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("anim done windows=2 frames=40 dropped=3 hitches=2 duration=400ms") },
            "\(lines)"
        )
        XCTAssertTrue(lines.contains("snapshot flight layers=2 cacheAgeMs=0 duration=400ms fps=111"), "\(lines)")
    }

    func testFramesOfTheLandingTokenSurviveAPassThatSettlesLater() {
        beginAndPrime()
        let (second, plan2) = slide(idA, from: a.offsetBy(dx: 100, dy: 0), by: 100)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        flight.layersFinished(2, frames: FlightFrameStats(presented: 30, expected: 30, hitches: 0, duration: 0.25))
        scheduler.runPending()
        XCTAssertTrue(flight.isActive, "the retarget's pass has not settled yet")
        flight.passSettled()
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("anim done windows=2 frames=30 dropped=0 hitches=0") })
    }

    func testRetargetReusesTheRunningFlight() {
        beginAndPrime()
        let (second, plan2) = slide(idA, from: a.offsetBy(dx: 100, dy: 0), by: 100)

        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)

        XCTAssertEqual(overlay.begins.count, 1)
        XCTAssertEqual(overlay.retargets.map(\.token), [2])
        XCTAssertEqual(overlay.retargets.first?.targets[idA], second.to)
        XCTAssertTrue(overlay.retargets.first?.adds.isEmpty == true)
        XCTAssertEqual(overlay.flies, [1], "a retarget in the air does not fly again")
        // The retarget's token is the one that settles.
        flight.layersFinished(1)
        flight.layersFinished(2)
        scheduler.runPending()
        flight.passSettled()
        XCTAssertEqual(overlay.ends, 1)
    }

    /// SM-16: only when no moving window has an image.
    func testCacheMissFallsBackAndRefreshesSoon() {
        refresh([idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)

        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .ax)

        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(overlay.begins.isEmpty)
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot fallback reason=cache-miss ids=1" })
        scheduler.advance(by: 0.05)
        XCTAssertEqual(world.captures.count, 2, "a refresh 50 ms later")
    }

    // MARK: SM-16 holes

    func testAWindowWithoutAnImageFliesThroughAHoleInsteadOfFallingBack() {
        refresh([idA: a])
        let (animation, plan) = slide(idA, from: a, by: 100)

        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)

        XCTAssertEqual(overlay.begins.first?.flights.first?.items.map(\.id), [idA])
        XCTAssertEqual(overlay.begins.first?.holes, [idB: b], "the real window shows through at its target")
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot fallback") })
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot holes ids=1") })
    }

    func testAHoleWindowIsPaintCheckedBeforeTheHandOff() {
        refresh([idA: a])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertEqual(world.paintChecks, [[idB: b]], "it came into view through its hole")
        XCTAssertEqual(overlay.ends, 0)
        answerPaint([idB: .painted])
        XCTAssertEqual(overlay.ends, 1)
    }

    func testAWindowUncoveredAtRetargetGetsAHole() {
        let parkedB = CGRect(x: 1799, y: b.minY, width: b.width, height: b.height)
        fixture.physicalFrames[idB] = parkedB
        refresh([idA: a])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        XCTAssertEqual(overlay.begins.first?.holes, [:], "parked: nothing to show through")
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()

        var visible = fixture.physicalFrames
        visible[idA] = a.offsetBy(dx: -100, dy: 0)
        visible[idB] = b
        let second = WindowAnimation(id: idB, from: parkedB, to: b, duration: 0.3)
        XCTAssertEqual(flight.drive(animations: [second], plans: [ParkingPlan(visible: visible)], spring: .niri), .flying)

        XCTAssertEqual(overlay.retargets.first?.holes, [idB: b])
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot holes ids=1") })
    }

    /// SM-13: the plan and the layers use one lookup per window, so an image
    /// at the edge of its age cannot pass the plan and then be missing from
    /// the opaque overlay (a hole where the window should be).
    func testThePlanAndTheLayersUseTheSameImage() {
        refresh([idA: a])
        scheduler.advance(by: 179.688)
        refresh([idB: b])
        // idA is 179.988 s old: 12 ms under the max age when the flight starts.
        world.cacheDriftPerRead = 0.005
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        XCTAssertEqual(overlay.begins.first?.flights.first?.items.map(\.id).sorted(), [idA, idB])
    }

    // MARK: SM-14 hand-off only when painted

    /// idA's parking sliver at the left edge of the screen.
    private var parkedA: CGRect { CGRect(x: -799, y: a.minY, width: a.width, height: a.height) }

    /// idA flies in from its parking frame (idB stays); the layers land and
    /// the pass settled: the hand-off starts.
    private func flyInFromParkedAndLand() {
        refresh([idA: a, idB: b])
        let animation = WindowAnimation(id: idA, from: parkedA, to: a, duration: 0.3)
        XCTAssertEqual(
            flight.drive(animations: [animation], plans: [ParkingPlan(visible: fixture.physicalFrames)], spring: .niri),
            .priming
        )
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()
        flight.layersFinished(1)
        scheduler.runPending()
    }

    private func answerPaint(_ verdicts: [WindowID: SnapshotPaintVerdict]) {
        world.paintAnswers.removeFirst()(verdicts)
        scheduler.runPending()
    }

    func testWindowsThatWereVisibleAndKeepTheirSizeHandOverAtOnce() {
        beginAndPrime()
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertTrue(world.paintChecks.isEmpty, "a window that painted before the flight is not checked")
        XCTAssertEqual(overlay.ends, 1)
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot handoff waited ms=0 windows=0 painted=0") })
    }

    func testAWindowFromItsParkingFrameHoldsTheOverlayUntilItPainted() {
        flyInFromParkedAndLand()
        XCTAssertEqual(world.paintChecks, [[idA: a]], "only the window that came from off screen, at its target")
        XCTAssertTrue(flight.isActive, "the overlay is held: still a flight for every other component")
        XCTAssertEqual(overlay.ends, 0)
        XCTAssertEqual(overlay.events.last, "collect", "the writes are folded at the landing, before the check")

        answerPaint([idA: .blank])
        XCTAssertEqual(world.paintChecks.count, 1, "the next check waits for its interval")
        scheduler.advance(by: SnapshotHandoff.recheckInterval)
        XCTAssertEqual(world.paintChecks.count, 2)
        XCTAssertEqual(overlay.ends, 0)

        answerPaint([idA: .painted])
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.events.suffix(2), ["publish", "end"], "ring and dim, then the overlay goes")
        XCTAssertEqual(world.renderChecks, 1)
        XCTAssertTrue(world.logs.contains { $0 == (.info, "snapshot handoff waited ms=30 windows=1 painted=1") })
    }

    func testTheHoldEndsAtTheCapWhenAWindowNeverPaints() {
        flyInFromParkedAndLand()
        answerPaint([idA: .blank])
        scheduler.advance(by: SnapshotHandoff.recheckInterval)
        XCTAssertEqual(world.paintChecks.count, 2, "a check is out and never answers")
        scheduler.advance(by: SnapshotHandoff.cap - SnapshotHandoff.recheckInterval - 0.001)
        XCTAssertEqual(overlay.ends, 0)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(overlay.ends, 1)
        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(world.logs.contains { $0 == (.info, "snapshot handoff waited ms=300 windows=1 painted=0") })
        answerPaint([idA: .painted])
        XCTAssertEqual(overlay.ends, 1, "a late answer changes nothing")
    }

    func testAKeyPressDuringTheHoldRetargetsAndCancelsIt() {
        flyInFromParkedAndLand()
        let (second, plan2) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        XCTAssertEqual(overlay.events.last, "retarget:2")
        XCTAssertEqual(overlay.retargets.first?.targets[idA], second.to)
        answerPaint([idA: .painted])
        scheduler.advance(by: SnapshotHandoff.cap)
        XCTAssertEqual(overlay.ends, 0, "the cancelled hold neither ends nor caps the retargeted flight")
        XCTAssertTrue(flight.isActive)

        flight.layersFinished(2)
        scheduler.runPending()
        flight.passSettled()
        XCTAssertEqual(
            world.paintChecks.last, [idA: second.to],
            "the window came from its parking frame at the flight start: checked at its new target"
        )
        XCTAssertEqual(overlay.ends, 0)
        answerPaint([idA: .painted])
        XCTAssertEqual(overlay.ends, 1)
    }

    func testAMouseDownDuringTheHoldSettlesWithoutAnotherEnd() {
        flyInFromParkedAndLand()
        flight.aborted(.mouseDown)
        scheduler.runPending()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, 0, "the overlay came down itself")
        XCTAssertEqual(overlay.events.last, "publish")
        answerPaint([idA: .painted])
        scheduler.advance(by: SnapshotHandoff.cap)
        XCTAssertEqual(overlay.ends, 0)
    }

    func testEndDuringTheHoldBringsTheOverlayDownOnce() {
        flyInFromParkedAndLand()
        flight.end()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, 1)
        answerPaint([idA: .blank])
        scheduler.advance(by: SnapshotHandoff.cap)
        XCTAssertEqual(overlay.ends, 1)
    }

    // MARK: SM-19 early paint check, trusted apps

    /// idA flies in from its parking frame; the overlay reports the deadline
    /// `flightTime` seconds out. Returns the flight's token.
    @discardableResult
    private func flyInFromParked(deadlineIn flightTime: TimeInterval = 0.3) -> Int {
        let animation = WindowAnimation(id: idA, from: parkedA, to: a, duration: 0.3)
        XCTAssertEqual(
            flight.drive(animations: [animation], plans: [ParkingPlan(visible: fixture.physicalFrames)], spring: .niri),
            .priming
        )
        let token = overlay.begins.last!.token
        deferPass()
        flight.primed(token, ok: true)
        scheduler.runPending()
        flight.deadlineArmed(token, at: scheduler.now + flightTime)
        scheduler.runPending()
        return token
    }

    func testAnEarlyCheckThatReadPaintedHandsOverAtTheDeadlineWithoutAHold() {
        refresh([idA: a, idB: b])
        let token = flyInFromParked()
        XCTAssertTrue(world.paintChecks.isEmpty, "not before the lead")
        scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead)
        XCTAssertEqual(world.paintChecks, [[idA: a]], "80 ms before the deadline, at the target")
        answerPaint([idA: .painted])
        XCTAssertEqual(overlay.ends, 0, "the layers are still flying")
        XCTAssertTrue(flight.isActive)

        scheduler.advance(by: SnapshotHandoff.earlyLead)
        flight.layersFinished(token)
        scheduler.runPending()
        XCTAssertEqual(overlay.ends, 1, "released at the deadline")
        XCTAssertEqual(world.paintChecks.count, 1, "no check after the landing")
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot handoff waited ms=0 windows=1 painted=1") })
    }

    func testAnEarlyBlankHoldsTheOverlayAtTheDeadline() {
        refresh([idA: a, idB: b])
        let token = flyInFromParked()
        scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead)
        answerPaint([idA: .blank])
        scheduler.advance(by: SnapshotHandoff.earlyLead)
        flight.layersFinished(token)
        scheduler.runPending()
        XCTAssertEqual(world.paintChecks.count, 2, "checked again at the landing")
        XCTAssertEqual(overlay.ends, 0)
        answerPaint([idA: .painted])
        XCTAssertEqual(overlay.ends, 1)
    }

    func testARetargetCancelsTheEarlyCheckAndOneRunsBeforeTheNewDeadline() {
        refresh([idA: a, idB: b])
        flyInFromParked()
        scheduler.advance(by: 0.1)
        let (second, plan2) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        let retargeted = overlay.retargets.last!.token
        scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead - 0.1)
        XCTAssertTrue(world.paintChecks.isEmpty, "the first flight's early check was cancelled")

        flight.deadlineArmed(retargeted, at: scheduler.now + 0.3)
        scheduler.runPending()
        scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead)
        XCTAssertEqual(world.paintChecks, [[idA: second.to]], "at the new target")
        answerPaint([idA: .painted])
        scheduler.advance(by: SnapshotHandoff.earlyLead)
        flight.layersFinished(retargeted)
        scheduler.runPending()
        flight.passSettled()
        XCTAssertEqual(overlay.ends, 1)
        XCTAssertEqual(world.paintChecks.count, 1)
    }

    func testAStaleDeadlineReportSchedulesNothing() {
        refresh([idA: a, idB: b])
        let token = flyInFromParked(deadlineIn: 10)
        flight.deadlineArmed(token + 1, at: scheduler.now + 0.3)
        scheduler.runPending()
        scheduler.advance(by: 0.3)
        XCTAssertTrue(world.paintChecks.isEmpty)
    }

    func testAnAppThatPaintedFiveTimesIsNotCheckedAnyMore() {
        refresh([idA: a, idB: b])
        for _ in 0..<PaintTrustBook.cleanChecksToTrust {
            let token = flyInFromParked()
            scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead)
            answerPaint([idA: .painted])
            scheduler.advance(by: SnapshotHandoff.earlyLead)
            flight.layersFinished(token)
            scheduler.runPending()
            XCTAssertFalse(flight.isActive)
        }
        XCTAssertEqual(world.paintChecks.count, PaintTrustBook.cleanChecksToTrust)

        let token = flyInFromParked()
        scheduler.advance(by: 0.3)
        flight.layersFinished(token)
        scheduler.runPending()
        XCTAssertEqual(world.paintChecks.count, PaintTrustBook.cleanChecksToTrust, "trusted: no check")
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(world.logs.last { $0.1.hasPrefix("snapshot handoff") }?.1, "snapshot handoff waited ms=0 windows=0 painted=0")
    }

    func testBurstDuringFlightMergesIntoOneReflow() {
        world.coalesced = true
        flight.scheduleReflow()
        flight.scheduleReflow()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: SnapshotFlightController.retargetDelay)
        XCTAssertEqual(world.reflows, 1)
        // Nothing coalesced: no reflow.
        flight.scheduleReflow()
        scheduler.advance(by: SnapshotFlightController.retargetDelay)
        XCTAssertEqual(world.reflows, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }
}
