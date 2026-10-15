import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// Records every call in order (`prime:N`, `fly:N`, `retarget:N`, `end`,
/// `fresh:N`, `fade`); the tests append `writes`, `fallback` and `publish`
/// to the same list.
final class FakeOverlay: OverlayPort, @unchecked Sendable {
    var events: [String] = []
    var begins: [(token: Int, flights: [OverlayFlight], holes: [WindowID: CGRect], decorations: OverlayDecorations)] = []
    var retargets: [(
        token: Int, targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>], adds: [OverlayFlight],
        holes: [WindowID: CGRect], decorations: OverlayDecorations
    )] = []
    var flies: [Int] = []
    var ends = 0
    var freshens: [(token: Int, faces: [WindowID: SnapshotFace<CGImage>])] = []
    var fades: [(windows: Set<WindowID>, duration: TimeInterval)] = []

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
        token: Int, targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>], adds: [OverlayFlight],
        holes: [WindowID: CGRect], decorations: OverlayDecorations
    ) {
        events.append("retarget:\(token)")
        retargets.append((token, targets, images, adds, holes, decorations))
    }

    func endFlight() {
        events.append("end")
        ends += 1
    }

    func freshenFlight(token: Int, faces: [WindowID: SnapshotFace<CGImage>]) {
        events.append("fresh:\(token)")
        freshens.append((token, faces))
    }

    func fadeOutFlight(windows: Set<WindowID>, duration: TimeInterval) {
        events.append("fade")
        fades.append((windows, duration))
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
        /// SM-14: the paint checks asked for (target frames) and their
        /// pending answers; SM-29: the probes they carried.
        var paintChecks: [[WindowID: CGRect]] = []
        var paintProbes: [[WindowID: SnapshotPaintProbe]] = []
        var paintAnswers: [@Sendable (SnapshotPaintAnswer) -> Void] = []
        /// SM-18: usable frames per display (nil: the display frames).
        var usableFrames: [CGRect]?
        /// SM-30: the fresh captures asked for and their pending answers.
        var freshProbes: [(id: WindowID, probe: SnapshotFreshProbe<CGImage>)] = []
        var freshAnswers: [@Sendable (SnapshotFreshRead<CGImage>?) -> Void] = []
        /// SM-31: the on-screen WindowServer windows the cache judges misses by.
        var serverWindows: [ServerWindow] = []
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
                serverWindows: { world.serverWindows },
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
                checkPaint: { probes, answer in
                    world.paintChecks.append(probes.mapValues(\.frame))
                    world.paintProbes.append(probes)
                    world.paintAnswers.append(answer)
                },
                captureFresh: { id, probe, answer in
                    world.freshProbes.append((id, probe))
                    world.freshAnswers.append(answer)
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
    /// told otherwise, a backdrop for the one display. `fills`: SM-27 edge
    /// fills of the captured images.
    @discardableResult
    private func refresh(
        _ images: [WindowID: CGRect], backdrop: Bool = true, fills: [WindowID: ThemeColor] = [:],
        misses: [WindowID: SnapshotMiss] = [:]
    ) -> CGImage {
        cache.schedule()
        scheduler.advance(by: 0.3)
        let done = world.completions.removeLast()
        let backdropImage = image()
        done(SnapshotCaptureOutcome(
            images: images.reduce(into: [:]) { $0[$1.key] = CapturedImage(image: image(), frame: $1.value, fill: fills[$1.key]) },
            backdrops: backdrop ? [CapturedBackdropImage(image: backdropImage, displayFrame: SessionFixture.screen)] : [],
            misses: misses
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

    // MARK: MM-04 / MM-10 far-side parks

    /// A window parking on the far side of its display (the near edge is
    /// another display) never flies across the display. MM-10 (2026-10-14
    /// recording: such columns vanished at the first overlay frame): its
    /// layer slides out by the shared edge to its strip frame instead, on its
    /// own display's overlay, which clips it there.
    func testAFarSideParkSlidesOutByTheSharedEdge() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        var parkedPlan = plan
        let far = CGRect(x: SessionFixture.screen.maxX - 1, y: b.minY, width: b.width, height: b.height)
        parkedPlan.visible.removeValue(forKey: idB)
        parkedPlan.parked[idB] = ParkedTarget(frame: far, edge: .right, display: SessionFixture.screen, farSide: true)
        let strip = b.offsetBy(dx: -(b.maxX + 20), dy: 0)
        XCTAssertEqual(
            flight.drive(
                animations: [animation], plans: [parkedPlan], spring: .niri,
                jumps: [idB: JumpPath(from: b, to: strip, display: SessionFixture.screen)]
            ),
            .priming
        )
        let items = overlay.begins.first?.flights.flatMap(\.items) ?? []
        let layer = items.first { $0.id == idB }
        XCTAssertEqual(layer?.from, b)
        XCTAssertEqual(layer?.to, strip, "out by the edge, not to the far side")
        XCTAssertEqual(items.first { $0.id == idA }?.from, a)
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
    /// the newest layout right after the fly.
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
        // Main's prime report is queued first; the press that arrived while
        // priming coalesced its request and queued the retarget behind it.
        flight.primed(1, ok: true)
        world.coalesced = true
        flight.scheduleReflow()

        scheduler.runPending()
        XCTAssertEqual(overlay.events, ["prime:1", "writes", "fly:1"])
        XCTAssertEqual(world.reflows, 1, "the request is put back after the writes and retargets at once")
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

    // MARK: SM-31 vanished and undrawn windows

    /// Both columns scroll 100 pt to the left.
    private func scrollBoth() -> (animations: [WindowAnimation], plan: ParkingPlan) {
        let toA = a.offsetBy(dx: -100, dy: 0)
        let toB = b.offsetBy(dx: -100, dy: 0)
        return (
            [WindowAnimation(id: idA, from: a, to: toA, duration: 0.3), WindowAnimation(id: idB, from: b, to: toB, duration: 0.3)],
            ParkingPlan(visible: [idA: toA, idB: toB])
        )
    }

    /// The reconciler found idB's AX element invalid (the session forgets
    /// its frame) while it stays in the layout: on the next motion it is
    /// neither a layer (its old picture would vanish at the hand-off) nor a
    /// hole, and idA still flies.
    func testAVanishedWindowIsNotALayerOnTheNextMotion() {
        refresh([idA: a, idB: b])
        cache.noteVanished([idB])
        fixture.physicalFrames.removeValue(forKey: idB)
        let (animation, _) = slide(idA, from: a, by: -100)
        let plan = ParkingPlan(visible: [idA: animation.to, idB: b])

        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)

        XCTAssertEqual(overlay.begins.first?.flights.first?.items.map(\.id), [idA])
        XCTAssertEqual(overlay.begins.first?.holes, [:], "nothing to show through either")
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot fallback") })
    }

    /// A capture found no WindowServer window for idB and nothing of its
    /// app is on screen: it is left out of every later flight (no layer,
    /// no hole, no AX fallback) while idA keeps flying, until a capture
    /// matches it again.
    func testAnUndrawnWindowIsNotALayerOnLaterMotionsUntilACaptureMatchesItAgain() {
        refresh([idA: a, idB: b])
        world.serverWindows = [ServerWindow(pid: 1, bounds: a)]
        scheduler.advance(by: 31)
        refresh([idA: a], misses: [idB: .unmatched])

        for flightNumber in 1...2 {
            let (animations, plan) = scrollBoth()
            XCTAssertEqual(flight.drive(animations: animations, plans: [plan], spring: .niri), .priming)
            XCTAssertEqual(overlay.begins.last?.flights.first?.items.map(\.id), [idA], "flight \(flightNumber)")
            XCTAssertEqual(overlay.begins.last?.holes, [:], "flight \(flightNumber)")
            flight.end()
        }
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot fallback") })

        world.serverWindows = [ServerWindow(pid: 1, bounds: a), ServerWindow(pid: 2, bounds: b)]
        refresh([idB: b])
        let (animations, plan) = scrollBoth()
        XCTAssertEqual(flight.drive(animations: animations, plans: [plan], spring: .niri), .priming)
        XCTAssertEqual(overlay.begins.last?.flights.first?.items.map(\.id).sorted(), [idA, idB], "matched again: flies")
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

    private func answerPaint(_ verdicts: [WindowID: SnapshotPaintVerdict], samples: [WindowID: [UInt32]] = [:]) {
        world.paintAnswers.removeFirst()(SnapshotPaintAnswer(verdicts: verdicts, samples: samples))
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

    // MARK: SM-29 resized windows always checked; partial and stale paints hold

    func testAResizedWindowOfATrustedAppIsCheckedAndHeldUntilItsRepaintSettles() {
        let fill = ThemeColor(red: 0.1, green: 0.1, blue: 0.1)
        refresh([idA: a, idB: b], fills: [idA: fill])
        for _ in 0..<PaintTrustBook.cleanChecksToTrust {
            let token = flyInFromParked()
            scheduler.advance(by: 0.3 - SnapshotHandoff.earlyLead)
            answerPaint([idA: .painted])
            scheduler.advance(by: SnapshotHandoff.earlyLead)
            flight.layersFinished(token)
            scheduler.runPending()
        }
        let checks = world.paintChecks.count

        // Alt+F: idA grows from the column size; no image of the new size yet.
        let wide = CGRect(x: 0, y: 100, width: 1600, height: 900)
        let (animation, plan) = resize(idA, from: a, to: wide)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        let token = overlay.begins.last!.token
        deferPass()
        flight.primed(token, ok: true)
        scheduler.runPending()
        flight.layersFinished(token)
        scheduler.runPending()

        XCTAssertEqual(world.paintChecks.count, checks + 1, "resized: checked although its app is trusted")
        XCTAssertEqual(
            world.paintProbes.last, [idA: SnapshotPaintProbe(frame: wide, resizedFrom: a.size, background: fill)],
            "the size it grew from and the background its image showed"
        )
        answerPaint([idA: .partial])
        scheduler.advance(by: SnapshotHandoff.recheckInterval)
        let settled: [UInt32] = (0..<45).map { UInt32($0) << 24 | 0xFF }
        answerPaint([idA: .painted], samples: [idA: settled])
        XCTAssertTrue(overlay.fades.isEmpty, "one painted read after a partial one is not enough")
        scheduler.advance(by: SnapshotHandoff.recheckInterval)
        answerPaint([idA: .painted], samples: [idA: settled])
        XCTAssertEqual(overlay.ends, PaintTrustBook.cleanChecksToTrust, "the pure moves before left at once")
        XCTAssertEqual(overlay.fades.map(\.windows), [[idA]], "SM-30: the resized layer fades out")
        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(world.logs.contains {
            $0 == (.info, "snapshot handoff waited ms=60 windows=1 painted=1 resized=1 held=partial fade=120")
        })
    }

    /// Keys already queued merge into one retarget, and it runs on the next
    /// turn of the session queue: no fixed wait between a key and its motion.
    func testBurstDuringFlightRetargetsAtOnceInOneReflow() {
        world.coalesced = true
        flight.scheduleReflow()
        flight.scheduleReflow()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runPending()
        XCTAssertEqual(world.reflows, 1)
        // Nothing coalesced: no reflow.
        flight.scheduleReflow()
        scheduler.runPending()
        XCTAssertEqual(world.reflows, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: SM-27 resize without stretching

    private let wide = CGRect(x: 0, y: 100, width: 1600, height: 900)

    /// Window A captured at the column size and maximized, B at its size.
    private func cacheBothSizesOfA() {
        refresh([idA: wide, idB: b])
        refresh([idA: a])
    }

    private func resize(_ id: WindowID, from: CGRect, to: CGRect) -> (WindowAnimation, ParkingPlan) {
        var visible = fixture.physicalFrames
        visible[id] = to
        return (WindowAnimation(id: id, from: from, to: to, duration: 0.3), ParkingPlan(visible: visible))
    }

    func testAResizingLayerCarriesTheImageOfItsTargetSizeAndEveryImageItsOwnSize() throws {
        cacheBothSizesOfA()
        let (animation, plan) = resize(idA, from: a, to: wide)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        let items = overlay.begins.first?.flights.flatMap(\.items) ?? []
        let item = try XCTUnwrap(items.first { $0.id == idA })
        XCTAssertEqual(item.image.size, a.size, "drawn at the size it was captured at")
        XCTAssertEqual(item.target?.size, wide.size)
        let still = try XCTUnwrap(items.first { $0.id == idB })
        XCTAssertTrue(still.target?.image === still.image.image, "a move: its own image again, nothing to fade")
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=swap") })
        XCTAssertEqual(world.logs.filter { $0.1.hasPrefix("snapshot resize") }.count, 1)
    }

    /// Alt+F while a scroll flies: the layer is told the image of its new
    /// size; a layer keeping its size is told the image it already shows,
    /// so a running fade carries on.
    func testARetargetGivesEveryLayerTheImageOfItsNewSize() throws {
        cacheBothSizesOfA()
        let (first, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [first], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot resize") })
        let (second, plan2) = resize(idA, from: first.to, to: wide)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        let retarget = try XCTUnwrap(overlay.retargets.first)
        XCTAssertEqual(retarget.images[idA]?.size, wide.size, "fade to the maximized image")
        XCTAssertEqual(retarget.images[idB]?.size, b.size, "same size: the image it already shows")
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=swap") })
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot resize id=2:") })
    }

    // MARK: SM-30 fresh image during resize flights, soft hand-off

    private let freshSamples: [UInt32] = (0..<45).map { UInt32($0) << 24 | 0xFF }

    private func answerFresh(_ read: SnapshotFreshRead<CGImage>?) {
        world.freshAnswers.removeFirst()(read)
        scheduler.runPending()
    }

    private func freshRead(
        _ image: CGImage, size: CGSize, fill: ThemeColor? = nil, samples: [UInt32]? = nil,
        startRegion: [UInt32]? = nil, freshRegion: [UInt32]? = nil
    ) -> SnapshotFreshRead<CGImage> {
        SnapshotFreshRead(
            image: image, fill: fill, windowSize: size, paint: .painted, samples: samples ?? freshSamples,
            startRegion: startRegion, freshRegion: freshRegion, cached: nil
        )
    }

    /// Drives a resize of A, defers the pass and reports the prime (the
    /// writes run): the flight's token.
    private func resizeAndPrime(from: CGRect, to: CGRect) -> Int {
        let (animation, plan) = resize(idA, from: from, to: to)
        XCTAssertEqual(flight.drive(animations: [animation], plans: [plan], spring: .niri), .priming)
        let token = overlay.begins.last!.token
        deferPass()
        flight.primed(token, ok: true)
        scheduler.runPending()
        return token
    }

    /// Live (Slack, first maximize): the whole flight showed the start image
    /// beside a flat box although Slack had repainted at its new size.
    func testAGrowingWindowIsCapturedAgainAtItsNewSizeMidFlightAndTheLayerFadesToIt() throws {
        let fill = ThemeColor(red: 0.1, green: 0.1, blue: 0.1)
        refresh([idA: a, idB: b], fills: [idA: fill])
        let token = resizeAndPrime(from: a, to: wide)
        XCTAssertTrue(world.freshProbes.isEmpty, "not before the write had time to land")
        scheduler.advance(by: SnapshotFreshTracker.firstDelay)
        XCTAssertEqual(world.freshProbes.map(\.id), [idA], "only the resized window")
        let probe = try XCTUnwrap(world.freshProbes.first?.probe)
        XCTAssertEqual(probe.paint, SnapshotPaintProbe(frame: wide, resizedFrom: a.size, background: fill))
        XCTAssertNil(probe.start, "a grow: its grown strips tell an old layout")
        XCTAssertNil(probe.cached, "first maximize: no image of the new size")

        let fresh = image()
        let freshFill = ThemeColor(red: 0.2, green: 0.2, blue: 0.2)
        answerFresh(freshRead(fresh, size: wide.size, fill: freshFill))
        XCTAssertEqual(overlay.freshens.first?.token, token)
        let face = try XCTUnwrap(overlay.freshens.first?.faces[idA])
        XCTAssertTrue(face.image === fresh)
        XCTAssertEqual(face.size, wide.size)
        XCTAssertEqual(face.fill, freshFill)
        let stored = try XCTUnwrap(cache.cache.entry(idA, matching: wide))
        XCTAssertTrue(stored.image === fresh, "the cache keeps it as the new-size image")
        XCTAssertEqual(stored.fill, freshFill)
        scheduler.advance(by: SnapshotFreshTracker.limit)
        XCTAssertEqual(world.freshProbes.count, 1, "done: no more captures")

        flight.layersFinished(token)
        scheduler.runPending()
        XCTAssertEqual(world.paintProbes.last?[idA]?.background, freshFill, "the fresh image's background")
        answerPaint([idA: .painted])
        XCTAssertEqual(overlay.ends, 0, "no hard cut")
        XCTAssertEqual(overlay.fades.first?.windows, [idA])
        XCTAssertEqual(overlay.fades.first?.duration, snapshotHandoffFadeDuration)
        XCTAssertEqual(overlay.events.suffix(2), ["publish", "fade"], "the live ring and dim first")
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=fill fresh=120 attempts=1") })
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot handoff waited ms=0 windows=1 painted=1 resized=1 fade=120" })
    }

    /// Live (VS Code, max to half): ~370 ms after the resize the real window
    /// still showed its maximized layout clipped to the half frame; an image
    /// of that would show the wrong layout. Retried; once caught repainting,
    /// two matching reads.
    func testAShrinkingWindowStillShowingItsOldLayoutIsCapturedAgainUntilTwoReadsAgree() throws {
        cacheBothSizesOfA()
        let token = resizeAndPrime(from: wide, to: a)
        scheduler.advance(by: SnapshotFreshTracker.firstDelay)
        let probe = try XCTUnwrap(world.freshProbes.last?.probe)
        XCTAssertEqual(probe.start?.size, wide.size, "the start image, to tell its clipped layout")
        XCTAssertEqual(probe.cached?.size, a.size, "the cached image of the new size")
        let old: [UInt32] = (0..<45).map { UInt32(200 - $0) << 16 | 0xFF }
        answerFresh(freshRead(image(), size: a.size, samples: old, startRegion: old, freshRegion: old))
        XCTAssertTrue(overlay.freshens.isEmpty, "stale: not shown")
        scheduler.advance(by: SnapshotFreshTracker.retryInterval)
        XCTAssertEqual(world.freshProbes.count, 2)
        answerFresh(freshRead(image(), size: a.size))
        XCTAssertTrue(overlay.freshens.isEmpty, "caught repainting: one read is not enough")
        scheduler.advance(by: SnapshotFreshTracker.retryInterval)
        let settled = image()
        answerFresh(freshRead(settled, size: a.size))
        XCTAssertTrue(overlay.freshens.first?.faces[idA]?.image === settled)
        flight.layersFinished(token)
        scheduler.runPending()
        answerPaint([idA: .painted])
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=swap fresh=200 attempts=3") })
    }

    func testAPureMoveIsNotCapturedAgainAndLeavesAtOnce() {
        beginAndPrime()
        scheduler.advance(by: SnapshotFreshTracker.limit)
        XCTAssertTrue(world.freshProbes.isEmpty)
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertEqual(overlay.ends, 1)
        XCTAssertTrue(overlay.fades.isEmpty)
        XCTAssertFalse(world.logs.contains { $0.1.contains("fresh=") || $0.1.contains("fade=") })
    }

    func testTheHandOffStopsTheFreshCapturesAndALateAnswerIsDropped() {
        refresh([idA: a, idB: b])
        let token = resizeAndPrime(from: a, to: wide)
        scheduler.advance(by: SnapshotFreshTracker.firstDelay)
        XCTAssertEqual(world.freshProbes.count, 1)
        flight.layersFinished(token)
        scheduler.runPending()
        answerPaint([idA: .painted])
        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=fill fresh=none attempts=1") })
        answerFresh(freshRead(image(), size: wide.size))
        XCTAssertTrue(overlay.freshens.isEmpty)
        XCTAssertNil(cache.cache.entry(idA, matching: wide), "a late image is not stored")
        scheduler.advance(by: SnapshotFreshTracker.limit)
        XCTAssertEqual(world.freshProbes.count, 1)
    }

    func testARetargetBackToTheStartSizeDropsTheFreshCapture() {
        refresh([idA: a, idB: b])
        _ = resizeAndPrime(from: a, to: wide)
        scheduler.advance(by: SnapshotFreshTracker.firstDelay)
        let (back, plan) = resize(idA, from: wide, to: a)
        XCTAssertEqual(flight.drive(animations: [back], plans: [plan], spring: .niri), .flying)
        answerFresh(freshRead(image(), size: wide.size))
        XCTAssertTrue(overlay.freshens.isEmpty, "the image of a size it no longer lands at")
        scheduler.advance(by: SnapshotFreshTracker.limit)
        XCTAssertEqual(world.freshProbes.count, 1, "back at its start size: nothing to capture")
    }

    /// Alt+F while a scroll flies: the retarget's write starts the series.
    func testAResizeThatStartsAsARetargetIsCapturedAfterItsWrite() throws {
        cacheBothSizesOfA()
        let (first, plan) = slide(idA, from: a, by: 100)
        XCTAssertEqual(flight.drive(animations: [first], plans: [plan], spring: .niri), .priming)
        deferPass()
        flight.primed(1, ok: true)
        scheduler.runPending()
        scheduler.advance(by: 0.05)
        XCTAssertTrue(world.freshProbes.isEmpty)
        let (second, plan2) = resize(idA, from: first.to, to: wide)
        XCTAssertEqual(flight.drive(animations: [second], plans: [plan2], spring: .niri), .flying)
        scheduler.advance(by: SnapshotFreshTracker.firstDelay)
        let probe = try XCTUnwrap(world.freshProbes.first?.probe)
        XCTAssertEqual(world.freshProbes.count, 1)
        XCTAssertEqual(probe.paint.frame, wide)
        XCTAssertEqual(probe.paint.resizedFrom, a.size)
        XCTAssertEqual(probe.cached?.size, wide.size)
    }
}
