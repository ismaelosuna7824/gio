import CoreGraphics
import XCTest
@testable import GioCore

/// WP-05: an opening window stays covered under the snapshot overlay until a
/// capture at its target size reads painted, then its image pops in (rises
/// and fades in) on the window-open animation; a bounded wait reveals it
/// without the pop. Pure.
final class WindowOpenPopTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private func win(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 400, height: 800) }
    private func below(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: 0, dy: -24) }
    private let spring = ResolvedAnimation(
        enabled: true, curve: .spring, spring: SpringParameters(dampingRatio: 1, stiffness: 800, epsilon: 0.0001),
        durationMilliseconds: 250
    )
    private let easeOut = ResolvedAnimation(
        enabled: true, curve: .easeOut, spring: .niri, durationMilliseconds: 200
    )

    // MARK: covered vs revealed

    func testAnOpeningWindowMidStripIsCoveredNotAHole() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(100), id(2): below(win(100))], targets: [id(1): win(500), id(2): win(100)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true },
            opening: [id(2)], covered: [id(2)]
        )
        XCTAssertEqual(
            decision,
            .snapshot(
                items: [SnapshotFlightItem(id: id(1), from: win(100), to: win(500), displayIndex: 0)],
                holes: [],
                covered: [SnapshotFlightItem(id: id(2), from: below(win(100)), to: win(100), displayIndex: 0)]
            )
        )
        XCTAssertEqual(decision.finalFrames, [id(1): win(500), id(2): win(100)], "the covered window is written too")
    }

    func testAnEntryOnlyOpenIsAnOverlayFlightWhenCovered() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): below(win(500))], targets: [id(1): win(0), id(2): win(500)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true },
            opening: [id(2)], covered: [id(2)]
        )
        guard case .snapshot(let items, let holes, let covered) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)], "the still neighbour is drawn by the overlay")
        XCTAssertEqual(holes, [])
        XCTAssertEqual(covered.map(\.id), [id(2)])
    }

    func testAnEntryOnlyOpenWithoutCoverStillFallsBackToAX() {
        let decision = planSnapshotFlight(
            starts: [id(1): win(0), id(2): below(win(500))], targets: [id(1): win(0), id(2): win(500)],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true },
            opening: [id(2)]
        )
        XCTAssertEqual(decision, .fallback(reason: .cacheMiss, missing: [id(2)]))
    }

    func testACoveredOpenWithoutABackdropFallsBack() {
        let decision = planSnapshotFlight(
            starts: [id(2): below(win(500))], targets: [id(2): win(500)],
            displays: [display], hasImage: { _ in false }, backdropReady: { _ in false },
            opening: [id(2)], covered: [id(2)]
        )
        XCTAssertEqual(decision, .fallback(reason: .noBackdrop, missing: []))
    }

    func testACoveredOpenThatDoesNotMoveStillGetsTheOverlay() {
        let decision = planSnapshotFlight(
            starts: [id(2): win(500)], targets: [id(2): win(500)],
            displays: [display], hasImage: { _ in false }, backdropReady: { _ in true },
            opening: [id(2)], covered: [id(2)]
        )
        XCTAssertEqual(
            decision,
            .snapshot(items: [], holes: [], covered: [SnapshotFlightItem(id: id(2), from: win(500), to: win(500), displayIndex: 0)])
        )
    }

    func testAnUndrawnOrParkedOpeningWindowIsNeverCovered() {
        let parked = CGRect(x: -3000, y: 0, width: 400, height: 800)
        let decision = planSnapshotFlight(
            starts: [id(1): win(100), id(2): below(win(500)), id(3): parked],
            targets: [id(1): win(0), id(2): win(500), id(3): parked],
            displays: [display], hasImage: { $0 == id(1) }, backdropReady: { _ in true },
            undrawn: [id(2)], opening: [id(2), id(3)], covered: [id(2), id(3)]
        )
        guard case .snapshot(let items, let holes, let covered) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(items.map(\.id), [id(1)])
        XCTAssertEqual(holes, [])
        XCTAssertEqual(covered, [])
    }

    // MARK: pop plan

    func testThePopPlanTakesTheEntriesStartFramesWhenWindowOpenAnimates() {
        let plan = planWindowOpenPops(
            entries: [id(2)], prepositions: [id(2): below(win(500)), id(3): win(900)], animation: spring
        )
        XCTAssertEqual(plan?.starts, [id(2): below(win(500))])
        XCTAssertEqual(plan?.windows, [id(2)])
        XCTAssertEqual(plan?.pop(id(2), to: win(500))?.from, below(win(500)))
        XCTAssertNil(plan?.pop(id(3), to: win(900)), "not an entry")
    }

    func testNoPopPlanWithoutEntriesOrWithWindowOpenOff() {
        XCTAssertNil(planWindowOpenPops(entries: [], prepositions: [id(2): win(0)], animation: spring))
        var off = spring
        off.enabled = false
        XCTAssertNil(planWindowOpenPops(entries: [id(2)], prepositions: [id(2): win(0)], animation: off))
        var instant = easeOut
        instant.durationMilliseconds = 0
        XCTAssertNil(planWindowOpenPops(entries: [id(2)], prepositions: [id(2): win(0)], animation: instant))
    }

    // MARK: pop timeline

    func testASpringPopRisesAndFadesInOnTheWindowOpenSpring() {
        let pop = WindowOpenPop(id: id(2), from: below(win(500)), to: win(500), animation: spring)
        let reference = WindowAnimation(id: id(2), from: below(win(500)), to: win(500), spring: spring.spring)
        XCTAssertEqual(pop.duration, reference.duration, accuracy: 1e-9)
        XCTAssertEqual(pop.frame(at: 0), below(win(500)))
        XCTAssertEqual(pop.frame(at: pop.duration), win(500))
        XCTAssertEqual(pop.opacity(at: 0), 0)
        XCTAssertEqual(pop.opacity(at: pop.duration), 1)
        let half = pop.duration / 2
        XCTAssertEqual(pop.frame(at: half), reference.frame(at: half))
        XCTAssertEqual(pop.opacity(at: half), reference.normalizedProgress(at: half), accuracy: 1e-9)
        var previous = 0.0
        for step in 0...20 {
            let opacity = pop.opacity(at: pop.duration * Double(step) / 20)
            XCTAssertGreaterThanOrEqual(opacity, previous)
            previous = opacity
        }
    }

    func testAnEaseOutPopUsesTheWindowOpenDuration() {
        let pop = WindowOpenPop(id: id(2), from: below(win(500)), to: win(500), animation: easeOut)
        XCTAssertEqual(pop.duration, 0.2, accuracy: 1e-9)
        let progress = eased(0.5, easing: .easeOut)
        XCTAssertEqual(pop.frame(at: 0.1).minY, -24 + 24 * CGFloat(progress), accuracy: 1e-6)
        XCTAssertEqual(pop.opacity(at: 0.1), progress, accuracy: 1e-9)
        XCTAssertEqual(pop.frame(at: 0.3), win(500))
    }

    func testPopKeyframesGoFromTheStartTransparentToTheTargetOpaque() {
        let pop = WindowOpenPop(id: id(2), from: below(win(500)), to: win(500), animation: easeOut)
        let keyframes = windowOpenPopKeyframes(pop, in: display, flipped: false, rate: 60)
        XCTAssertEqual(keyframes.flight.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(keyframes.flight.times.count, 13)
        XCTAssertEqual(keyframes.flight.times.first, 0)
        XCTAssertEqual(keyframes.flight.times.last, 1)
        XCTAssertEqual(keyframes.opacities.count, keyframes.flight.times.count)
        XCTAssertEqual(keyframes.opacities.first, 0)
        XCTAssertEqual(keyframes.opacities.last, 1)
        XCTAssertEqual(
            keyframes.flight.geometries.first, overlayLayerGeometry(frame: below(win(500)), in: display, flipped: false)
        )
        XCTAssertEqual(keyframes.flight.geometries.last, overlayLayerGeometry(frame: win(500), in: display, flipped: false))
        XCTAssertEqual(keyframes.opacities[6], pop.opacity(at: 0.1), accuracy: 1e-9)
    }

    func testThePopKeepsTheOverlayWatchdogAtLeastItsDefault() {
        let pop = WindowOpenPop(id: id(2), from: below(win(500)), to: win(500), animation: easeOut)
        XCTAssertEqual(pop.watchdogLimit, FlightWatchdog.defaultLimit)
        var slow = easeOut
        slow.durationMilliseconds = 2000
        let long = WindowOpenPop(id: id(2), from: below(win(500)), to: win(500), animation: slow)
        XCTAssertEqual(long.watchdogLimit, 2 + SnapshotHandoff.watchdogMargin, accuracy: 1e-9)
    }

    // MARK: bounded wait

    private func popOf(_ n: UInt64) -> WindowOpenPop {
        WindowOpenPop(id: id(n), from: below(win(500)), to: win(500), animation: spring)
    }

    func testAPaintedCaptureAtTheTargetSizePopsTheWindow() {
        var book = WindowOpenPopBook()
        let token = book.cover(popOf(2), now: 10)
        XCTAssertEqual(book.covered, [id(2)])
        XCTAssertTrue(book.isWaiting(id(2), token: token))
        XCTAssertEqual(book.record(id(2), token: token, verdict: .fresh, now: 10.25), .pop(popOf(2), waited: 0.25))
        XCTAssertFalse(book.isWaiting(id(2), token: token), "popping, not waiting")
        XCTAssertEqual(book.covered, [id(2)], "still no hole while it pops")
        XCTAssertNil(book.expire(id(2), token: token, now: 10.4), "a popping window is not timed out")
        XCTAssertTrue(book.popped(id(2), token: token))
        XCTAssertTrue(book.isEmpty)
    }

    func testAnUnpaintedReadIsRetriedWithinTheWaitOnly() {
        var book = WindowOpenPopBook()
        let token = book.cover(popOf(2), now: 10)
        XCTAssertEqual(
            book.record(id(2), token: token, verdict: .blank, now: 10.1),
            .retry(after: WindowOpenPopBook.retryInterval)
        )
        XCTAssertEqual(book.record(id(2), token: token, verdict: .partial, now: 10.38), .wait, "no retry past the wait")
        XCTAssertNil(book.record(id(2), token: token + 1, verdict: .fresh, now: 10.39), "another series")
    }

    func testTheWaitEndsWithTheReasonOfTheLastRead() {
        let cases: [(SnapshotFreshVerdict?, WindowOpenRevealReason)] = [
            (.blank, .blank), (.partial, .timeout), (.stale, .timeout), (.unknown, .noCapture), (nil, .noCapture),
        ]
        for (verdict, reason) in cases {
            var book = WindowOpenPopBook()
            let token = book.cover(popOf(2), now: 10)
            if let verdict {
                _ = book.record(id(2), token: token, verdict: verdict, now: 10.1)
            }
            XCTAssertNil(book.expire(id(2), token: token, now: 10.39), "\(String(describing: verdict)): not yet")
            XCTAssertEqual(book.expire(id(2), token: token, now: 10.4), reason, "\(String(describing: verdict))")
            XCTAssertTrue(book.isEmpty)
        }
        XCTAssertEqual(WindowOpenPopBook.maxWait, 0.4)
    }

    func testARetargetRevealsTheWindowsWhoseTargetMoved() {
        var book = WindowOpenPopBook()
        _ = book.cover(popOf(2), now: 10)
        _ = book.cover(WindowOpenPop(id: id(3), from: below(win(0)), to: win(0), animation: spring), now: 10)
        _ = book.cover(WindowOpenPop(id: id(4), from: below(win(100)), to: win(100), animation: spring), now: 10)
        let moved = book.retarget([id(2): win(500), id(3): win(40)])
        XCTAssertEqual(moved, [id(3), id(4)], "moved, or no longer a target")
        XCTAssertEqual(book.covered, [id(2)])
    }

    func testRemovingAllReturnsTheCoveredWindows() {
        var book = WindowOpenPopBook()
        let token = book.cover(popOf(2), now: 10)
        _ = book.cover(WindowOpenPop(id: id(3), from: below(win(0)), to: win(0), animation: spring), now: 10)
        XCTAssertEqual(book.removeAll(), [id(2), id(3)])
        XCTAssertTrue(book.isEmpty)
        XCTAssertNil(book.expire(id(2), token: token, now: 11), "a removed window's timer no-ops")
    }

    func testLogLinesCarryIdsAndTimingsOnly() {
        XCTAssertEqual(windowOpenPopLine(id(2), waited: 0.1534), "snapshot open pop id=10:2 waited ms=153")
        XCTAssertEqual(windowOpenRevealLine(id(2), reason: .noCapture), "snapshot open reveal id=10:2 reason=noCapture")
        XCTAssertEqual(windowOpenRevealLine(id(2), reason: .timeout), "snapshot open reveal id=10:2 reason=timeout")
    }
}
