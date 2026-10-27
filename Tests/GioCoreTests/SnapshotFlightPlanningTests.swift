import CoreGraphics
import XCTest
@testable import GioCore

/// SM-04: renderer choice per motion (snapshot vs AX fallback), retarget
/// merge, completion gate and log lines. Pure.
final class SnapshotFlightPlanningTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let other = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    private func win(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 400, height: 800) }
    private let all: (WindowID) -> Bool = { _ in true }

    // MARK: plan selection

    func testEveryVisibleWindowWithAnImageMakesASnapshotFlight() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, _, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1), id(2)])
        XCTAssertEqual(items[1].from, win(400))
        XCTAssertEqual(items[1].to, win(100))
        XCTAssertEqual(items.map(\.displayIndex), [0, 0])
    }

    func testAStaticVisibleWindowIsStillDrawnBecauseTheOverlayCoversIt() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(0), id(2): win(500)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, _, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1), id(2)])
    }

    /// FX-09 (recording 2026-10-21 19:22): OrbStack did not move while the
    /// focus went to and from it, but its layer swapped the real window for
    /// an image of its inactive look at the start and back at the end, while
    /// OrbStack itself repaints its active look ~200 ms late: inactive,
    /// active, inactive. A layered window that keeps its frame is drawn
    /// through a hole (its layer keeps only the ring, dim and shadow); an
    /// opening one keeps its own handling.
    func testAWindowThatKeepsItsFrameIsSeenThroughNotDrawn() {
        let items = [
            SnapshotFlightItem(id: id(1), from: win(0), to: win(0), displayIndex: 0),
            SnapshotFlightItem(id: id(2), from: win(400), to: win(500), displayIndex: 0),
            SnapshotFlightItem(id: id(3), from: win(0), to: win(0.5), displayIndex: 0),
            SnapshotFlightItem(id: id(4), from: win(600), to: win(600), displayIndex: 0),
        ]
        XCTAssertEqual(snapshotStillWindows(items, opening: [id(4)]), [id(1), id(3)], "half a point is no move")
        var resized = win(0)
        resized.size.width = 380
        XCTAssertEqual(
            snapshotStillWindows([SnapshotFlightItem(id: id(1), from: win(0), to: resized, displayIndex: 0)], opening: []),
            [], "a resize changes the picture"
        )
    }

    /// SM-16: no more all-or-nothing. A visible window without an image
    /// is a hole in the backdrop at its target; the real window, written
    /// there at the start, shows through.
    func testAVisibleWindowWithoutAnImageIsAHoleAtItsTarget() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        XCTAssertEqual(
            decision,
            .snapshot(
                items: [SnapshotFlightItem(id: id(1), from: win(0), to: win(-300), displayIndex: 0)],
                holes: [SnapshotHole(id: id(2), frame: win(100), displayIndex: 0)]
            )
        )
    }

    func testWithoutAnImageOfAnyMovingWindowTheMotionFallsBackToAX() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(0), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision, .fallback(reason: .cacheMiss, missing: [id(2)]), "only the static window has an image")
    }

    func testAWindowLeavingForItsParkingFrameWithoutAnImageHasNoHole() {
        let parked = CGRect(x: -3000, y: 0, width: 400, height: 800)
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(50), id(2): parked],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
        XCTAssertEqual(holes, [])
        XCTAssertEqual(decision.finalFrames, [id(1): win(50)])
    }

    func testAWindowParkedBeforeAndAfterNeedsNoImage() {
        let parkedA = CGRect(x: -3000, y: 0, width: 400, height: 800)
        let parkedB = CGRect(x: -3100, y: 0, width: 400, height: 800)
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(9): parkedA], targets: [id(1): win(50), id(9): parkedB],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, _, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
    }

    func testAWindowScrollingInFromParkedWithoutAnImageIsAHole() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(9): CGRect(x: -3000, y: 0, width: 400, height: 800)],
            targets: [id(1): win(-300), id(9): win(500)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
        XCTAssertEqual(holes, [SnapshotHole(id: id(9), frame: win(500), displayIndex: 0)])
        XCTAssertEqual(decision.finalFrames, [id(1): win(-300), id(9): win(500)], "the hole window is written too")
    }

    func testOnlyDisplaysWithMovingWindowsGetLayers() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(1000)], targets: [id(1): win(50), id(2): win(1000)],
            displays: [display, other], hasImage: { $0 == id(1) }, backdropReady: { _ in true }
        )
        guard case .snapshot(let items, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
        XCTAssertEqual(holes, [], "a display without motion gets no overlay, so no hole")
    }

    /// MM-10: a layer sliding out by an edge another display shares ends on
    /// that display; pinned to its own display, that overlay clips it at the
    /// edge instead of the other display drawing it.
    func testAPinnedLayerStaysOnItsOwnDisplayPastASharedEdge() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(600)], targets: [id(1): win(1100)],
            displays: [display, other], hasImage: all, backdropReady: { _ in true },
            pinnedDisplays: [id(1): 0]
        )
        guard case .snapshot(let items, _, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.displayIndex), [0])
        let retarget = planSnapshotRetarget(
            active: [], starts: [id(1): win(600)], targets: [id(1): win(1100)],
            displays: [display, other], activeDisplays: [0], hasImage: all, pinnedDisplays: [id(1): 0]
        )
        XCTAssertEqual(retarget.adds.map(\.displayIndex), [0])
    }

    func testNothingMovingOnScreenIsNotASnapshotFlight() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0)], targets: [id(1): win(0)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision, .fallback(reason: .nothingVisible, missing: []))
    }

    func testAMissingBackdropFallsBack() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0)], targets: [id(1): win(50)],
            displays: [display], hasImage: all, backdropReady: { _ in false }
        )
        XCTAssertEqual(decision, .fallback(reason: .noBackdrop, missing: []))
    }

    func testARealWindowGetsExactlyOneWriteToItsFinalFrame() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: all, backdropReady: { _ in true }
        )
        XCTAssertEqual(decision.finalFrames, [id(1): win(-300), id(2): win(100)])
    }

    // MARK: retarget merge

    func testRetargetKeepsLayersAddsNewOnesAndReportsUncovered() {
        let plan = planSnapshotRetarget(
            active: [id(1), id(2)],
            starts: [id(1): win(-300), id(2): win(100), id(3): win(2000), id(4): win(2500)],
            targets: [id(1): win(-700), id(2): win(-300), id(3): win(100), id(4): win(500)],
            displays: [display], activeDisplays: [0], hasImage: { $0 != id(4) }
        )
        XCTAssertEqual(plan.retargets, [id(1): win(-700), id(2): win(-300)])
        XCTAssertEqual(plan.adds.map(\.id), [id(3)])
        XCTAssertEqual(plan.adds.first?.from, win(2000))
        XCTAssertEqual(plan.uncovered, [id(4)])
    }

    func testRetargetIgnoresWindowsThatStayOffScreen() {
        let plan = planSnapshotRetarget(
            active: [id(1)], starts: [id(1): win(0), id(9): win(-3000)],
            targets: [id(1): win(50), id(9): win(-3100)],
            displays: [display], activeDisplays: [0], hasImage: { $0 == id(1) }
        )
        XCTAssertEqual(plan.adds, [])
        XCTAssertEqual(plan.uncovered, [])
    }

    // MARK: SM-16 holes

    func testHolesAreTheWindowsVisibleAtTheirTargetWithoutALayer() {
        let holes = snapshotHoles(
            layered: [id(1)],
            targets: [
                id(1): win(0), id(2): win(400), id(3): CGRect(x: -3000, y: 0, width: 400, height: 800),
                id(4): CGRect(x: -399, y: 0, width: 400, height: 800), id(5): win(1200), id(6): win(700),
            ],
            displays: [display, other], activeDisplays: [0]
        )
        XCTAssertEqual(
            holes,
            [SnapshotHole(id: id(2), frame: win(400), displayIndex: 0), SnapshotHole(id: id(6), frame: win(700), displayIndex: 0)],
            "layered, parked, a parking sliver and a window on a display without an overlay have no hole"
        )
    }

    func testAWindowThatGetsALayerLosesItsHole() {
        let targets = [id(1): win(0), id(2): win(400)]
        XCTAssertEqual(
            snapshotHoles(layered: [id(1)], targets: targets, displays: [display], activeDisplays: [0]).map(\.id), [id(2)]
        )
        XCTAssertEqual(
            snapshotHoles(layered: [id(1), id(2)], targets: targets, displays: [display], activeDisplays: [0]), []
        )
    }

    func testAnUncoveredWindowAtRetargetIsAHoleAtItsNewTarget() {
        let plan = planSnapshotRetarget(
            active: [id(1)], starts: [id(1): win(0), id(4): CGRect(x: -3000, y: 0, width: 400, height: 800)],
            targets: [id(1): win(-300), id(4): win(500)],
            displays: [display], activeDisplays: [0], hasImage: { $0 == id(1) }
        )
        XCTAssertEqual(plan.uncovered, [id(4)])
        XCTAssertEqual(
            snapshotHoles(
                layered: [id(1)], targets: [id(1): win(-300), id(4): win(500)], displays: [display], activeDisplays: [0]
            ),
            [SnapshotHole(id: id(4), frame: win(500), displayIndex: 0)]
        )
    }

    func testHolesLine() {
        XCTAssertEqual(snapshotHolesLine(count: 3, entries: 1), "snapshot holes ids=3 entries=1")
    }

    // MARK: WP-04 entry holes

    /// A window opening in this pass without an image is an entry hole: it
    /// cuts the image layers too, so the neighbour it displaces slides out
    /// from under it instead of covering it.
    func testAnOpeningWindowWithoutAnImageIsAnEntryHole() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(100), id(2): win(100)], targets: [id(1): win(500), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }, opening: [id(2)]
        )
        guard case .snapshot(let items, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
        XCTAssertEqual(holes, [SnapshotHole(id: id(2), frame: win(100), displayIndex: 0, entry: true)])
    }

    func testAWindowThatIsNotOpeningStaysAnOrdinaryHole() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400), id(3): win(700)],
            targets: [id(1): win(-300), id(2): win(100), id(3): win(700)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }, opening: [id(3)]
        )
        guard case .snapshot(_, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(holes, [
            SnapshotHole(id: id(2), frame: win(100), displayIndex: 0),
            SnapshotHole(id: id(3), frame: win(700), displayIndex: 0, entry: true),
        ])
    }

    func testAnUndrawnOpeningWindowHasNoHole() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(100), id(2): win(100)], targets: [id(1): win(500), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }, undrawn: [id(2)],
            opening: [id(2)]
        )
        guard case .snapshot(_, let holes, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(holes, [])
    }

    func testARetargetKeepsTheEntryHoleUntilTheWindowHasALayer() {
        let targets = [id(1): win(600), id(2): win(100)]
        XCTAssertEqual(
            snapshotHoles(layered: [id(1)], targets: targets, displays: [display], activeDisplays: [0], opening: [id(2)]),
            [SnapshotHole(id: id(2), frame: win(100), displayIndex: 0, entry: true)]
        )
        XCTAssertEqual(
            snapshotHoles(
                layered: [id(1), id(2)], targets: targets, displays: [display], activeDisplays: [0], opening: [id(2)]
            ),
            []
        )
    }

    func testOverlayHolesCutTheImagesOnlyAtEntryHoles() {
        let holes = OverlayHoles(holes: [id(1): win(100), id(2): win(500)], entries: [id(2)])
        XCTAssertEqual(holes.backdrop, [win(100), win(500)])
        XCTAssertEqual(holes.images, [win(500)])
        XCTAssertEqual(OverlayHoles(holes: [id(1): win(100)], entries: []).images, [])
        XCTAssertEqual(OverlayHoles(), OverlayHoles(holes: [:], entries: []))
    }

    // MARK: SM-31 undrawn windows

    /// A window macOS does not draw (vanished, or a capture found no
    /// WindowServer window for it on screen) has nothing to fly: no layer,
    /// no hole, and it is not a miss, so the drawn windows still fly.
    func testAnUndrawnWindowIsNeitherALayerNorAHoleNorAMiss() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(-300), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }, undrawn: [id(2)]
        )
        XCTAssertEqual(
            decision,
            .snapshot(items: [SnapshotFlightItem(id: id(1), from: win(0), to: win(-300), displayIndex: 0)], holes: [])
        )
    }

    /// An undrawn window never counts as a miss, so it cannot make the
    /// motion fall back for want of its image (`cache-miss`); when only
    /// undrawn windows move, nothing visible moves.
    func testAMotionOfUndrawnWindowsAloneHasNothingVisibleAndNoMiss() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): win(400)], targets: [id(1): win(0), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true }, undrawn: [id(2)]
        )
        XCTAssertEqual(decision, .fallback(reason: .nothingVisible, missing: []))
    }

    func testAnUndrawnWindowJoiningAtRetargetIsNeitherAddedNorUncovered() {
        let plan = planSnapshotRetarget(
            active: [id(1)], starts: [id(1): win(0), id(4): win(2000), id(5): win(2500)],
            targets: [id(1): win(-300), id(4): win(100), id(5): win(500)],
            displays: [display], activeDisplays: [0], hasImage: { $0 != id(5) }, undrawn: [id(4), id(5)]
        )
        XCTAssertEqual(plan.retargets, [id(1): win(-300)])
        XCTAssertEqual(plan.adds, [])
        XCTAssertEqual(plan.uncovered, [])
    }

    func testAnUndrawnWindowHasNoHole() {
        XCTAssertEqual(
            snapshotHoles(
                layered: [id(1)], targets: [id(1): win(0), id(2): win(400), id(3): win(700)],
                displays: [display], activeDisplays: [0], undrawn: [id(3)]
            ),
            [SnapshotHole(id: id(2), frame: win(400), displayIndex: 0)]
        )
    }

    // MARK: gate

    func testTheFlightSettlesOnlyWhenLayersAndTheFinalPassAreBothDone() {
        var gate = SnapshotFlightGate()
        let token = gate.begin()
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.layersFinished(token))
        XCTAssertTrue(gate.passSettled(token))
    }

    func testSettleFiresOnceAndAStaleTokenIsIgnored() {
        var gate = SnapshotFlightGate()
        let first = gate.begin()
        let second = gate.retarget()
        XCTAssertFalse(gate.layersFinished(first))
        XCTAssertFalse(gate.passSettled(first))
        XCTAssertFalse(gate.passSettled(second))
        XCTAssertTrue(gate.layersFinished(second))
        XCTAssertFalse(gate.layersFinished(second))
        XCTAssertFalse(gate.isActive)
    }

    func testAbortMakesEveryTokenStale() {
        var gate = SnapshotFlightGate()
        let token = gate.begin()
        gate.abort()
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.layersFinished(token))
        XCTAssertFalse(gate.passSettled(token))
    }

    // MARK: log lines

    func testLogLines() {
        XCTAssertEqual(
            snapshotFlightLine(layers: 3, cacheAgeMilliseconds: 2500, duration: 0.356),
            "snapshot flight layers=3 cacheAgeMs=2500 duration=356ms"
        )
        XCTAssertEqual(snapshotFallbackLine(reason: .cacheMiss, count: 2), "snapshot fallback reason=cache-miss ids=2")
        XCTAssertEqual(snapshotFallbackLine(reason: .noBackdrop, count: 0), "snapshot fallback reason=no-backdrop ids=0")
        XCTAssertEqual(snapshotFallbackLine(reason: .primeFailed, count: 3), "snapshot fallback reason=prime-failed ids=3")
    }

    func testAbortLinesNameTheReason() {
        XCTAssertEqual(snapshotAbortLine(reason: .watchdog), "snapshot flight aborted reason=watchdog")
        XCTAssertEqual(snapshotAbortLine(reason: .mouseDown), "snapshot flight aborted reason=mouse-down")
        XCTAssertEqual(snapshotAbortLine(reason: .displayChange), "snapshot flight aborted reason=display-change")
    }

    func testOnlyTheWatchdogIsAWarning() {
        XCTAssertEqual(SnapshotAbortReason.watchdog.logLevel, .warn)
        XCTAssertEqual(SnapshotAbortReason.mouseDown.logLevel, .info)
        XCTAssertEqual(SnapshotAbortReason.displayChange.logLevel, .info)
    }

    func testAnimDoneLineNamesTheRenderer() {
        let ax = MotionSummary(windows: 1, frames: 2, dropped: 0, duration: 0.2, slowest: nil)
        XCTAssertTrue(ax.logLine.hasSuffix("renderer=ax grewAtStart=0"))
        let snap = MotionSummary(windows: 1, frames: 0, dropped: 0, duration: 0.2, slowest: nil, curve: "spring", renderer: "snapshot")
        XCTAssertTrue(snap.logLine.hasSuffix("curve=spring sizeAnimated=0 renderer=snapshot grewAtStart=0"))
    }

    // MARK: SM-12 frame measurement

    func testFrameStatsCountPresentedDroppedAndHitches() {
        // 120 Hz for 100 ms: 12 frames expected. Ten callbacks, two of them
        // late (one 2-frame gap, one 3-frame gap).
        let interval = 1.0 / 120
        let intervals = [Double](repeating: interval, count: 8) + [interval * 2, interval * 3]
        let stats = flightFrameStats(intervals: intervals, refreshRate: 120, duration: 0.1)
        XCTAssertEqual(stats.presented, 10)
        XCTAssertEqual(stats.expected, 12)
        XCTAssertEqual(stats.dropped, 2)
        XCTAssertEqual(stats.hitches, 2)
        XCTAssertEqual(stats.framesPerSecond, 100, accuracy: 0.001)
    }

    func testAHitchIsAnIntervalOverOneAndAHalfRefreshIntervals() {
        let interval = 1.0 / 60
        let stats = flightFrameStats(
            intervals: [interval * 1.4, interval * 1.5, interval * 1.51], refreshRate: 60, duration: 0.05
        )
        XCTAssertEqual(stats.hitches, 1, "jitter up to 1.5x is not a hitch")
    }

    func testDroppedNeverGoesNegative() {
        // More callbacks than the nominal rate (a late deadline): nothing dropped.
        let stats = flightFrameStats(
            intervals: [Double](repeating: 1.0 / 60, count: 8), refreshRate: 60, duration: 0.1
        )
        XCTAssertEqual(stats.expected, 6)
        XCTAssertEqual(stats.dropped, 0)
    }

    func testTheMeterOnlyCountsWhileRunning() {
        var meter = FlightFrameMeter()
        meter.frame(at: 1)
        XCTAssertFalse(meter.isRunning)
        XCTAssertNil(meter.finish(at: 2), "no flight, no stats")
        meter.start(at: 10, refreshRate: 60)
        XCTAssertTrue(meter.isRunning)
        meter.frame(at: 10)
        meter.frame(at: 10 + 1.0 / 60)
        meter.frame(at: 10 + 4.0 / 60)
        let stats = meter.finish(at: 10 + 6.0 / 60)
        XCTAssertEqual(stats?.presented, 2)
        XCTAssertEqual(stats?.expected, 6)
        XCTAssertEqual(stats?.hitches, 1, "the 3-frame gap")
        XCTAssertEqual(stats?.duration ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertFalse(meter.isRunning)
        meter.frame(at: 11)
        XCTAssertNil(meter.finish(at: 12), "a finished meter stays at rest")
        meter.start(at: 20, refreshRate: 60)
        meter.cancel()
        XCTAssertFalse(meter.isRunning)
        XCTAssertNil(meter.finish(at: 21), "a cancelled flight reports nothing")
    }

    func testTheMeterStartsAtTheFirstDisplayCallback() {
        // SM-13: 30 ms of setup and vsync wait before the first callback are
        // neither expected frames nor a hitch.
        var meter = FlightFrameMeter()
        meter.start(at: 10, refreshRate: 120)
        let first = 10.03
        for frame in 0...12 {
            meter.frame(at: first + Double(frame) / 120)
        }
        let stats = meter.finish(at: first + 12.0 / 120)
        XCTAssertEqual(stats?.presented, 12)
        XCTAssertEqual(stats?.expected, 12)
        XCTAssertEqual(stats?.dropped, 0)
        XCTAssertEqual(stats?.hitches, 0)
        XCTAssertEqual(stats?.duration ?? 0, 0.1, accuracy: 1e-9)
    }

    func testAFlightWithoutAnyCallbackIsMeasuredFromItsStart() {
        var meter = FlightFrameMeter()
        meter.start(at: 10, refreshRate: 60)
        let stats = meter.finish(at: 10.1)
        XCTAssertEqual(stats?.presented, 0)
        XCTAssertEqual(stats?.expected, 6, "the screen never refreshed: every frame dropped")
    }

    func testSnapshotAnimDoneReportsPresentedFramesDroppedAndHitches() {
        let stats = FlightFrameStats(presented: 40, expected: 43, hitches: 2, duration: 0.36)
        XCTAssertEqual(
            MotionSummary.snapshotFlight(windows: 3, duration: 0.4, frames: stats).logLine,
            "anim done windows=3 frames=40 dropped=3 hitches=2 duration=400ms slowest=none curve=spring sizeAnimated=0 renderer=snapshot grewAtStart=0"
        )
        XCTAssertEqual(
            MotionSummary.snapshotFlight(windows: 3, duration: 0.4, frames: nil).logLine,
            "anim done windows=3 frames=0 dropped=0 duration=400ms slowest=none curve=spring sizeAnimated=0 renderer=snapshot grewAtStart=0",
            "no display link (macOS 13): nothing measured, no hitches field"
        )
        XCTAssertEqual(
            MotionSummary(windows: 2, frames: 25, dropped: 1, duration: 0.2, slowest: nil).logLine,
            "anim done windows=2 frames=25 dropped=1 duration=200ms slowest=none curve=ease-out sizeAnimated=0 renderer=ax grewAtStart=0",
            "the AX line is unchanged"
        )
    }

    func testSnapshotFlightLineReportsFramesPerSecond() {
        let stats = FlightFrameStats(presented: 42, expected: 43, hitches: 0, duration: 0.356)
        XCTAssertEqual(
            snapshotFlightLine(layers: 3, cacheAgeMilliseconds: 2500, duration: 0.4, frames: stats),
            "snapshot flight layers=3 cacheAgeMs=2500 duration=400ms fps=118"
        )
    }
}
