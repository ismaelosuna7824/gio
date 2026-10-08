import CoreGraphics
import XCTest
@testable import GioCore

/// SM-14: the hand-off from the overlay to the real windows. Which windows
/// must prove they painted before the overlay goes, how long the overlay is
/// held for them, and the log line. Pure.
final class SnapshotHandoffTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let other = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    private func win(_ x: CGFloat, width: CGFloat = 400) -> CGRect { CGRect(x: x, y: 0, width: width, height: 800) }
    /// A parked window: a 1 pt sliver at the left edge.
    private let parked = CGRect(x: -399, y: 0, width: 400, height: 800)

    // MARK: paint-check set

    func testAWindowComingFromItsParkingFrameMustProveItPainted() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): parked], targets: [id(1): win(0)], screens: [display], covered: [display]
        )
        XCTAssertEqual(ids, [id(1)])
    }

    func testAWindowComingFromAnotherWorkspaceOrWithoutAKnownStartMustProveItPainted() {
        // Another workspace's windows are parked on the far side; a window
        // with no physical frame yet has no start at all.
        let farParked = CGRect(x: 999, y: 0, width: 400, height: 800)
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): farParked], targets: [id(1): win(100), id(2): win(500)],
            screens: [display], covered: [display]
        )
        XCTAssertEqual(ids, [id(1), id(2)])
    }

    func testAResizedWindowMustProveItPaintedEvenWhenItWasVisible() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): win(0, width: 400)], targets: [id(1): win(0, width: 900)],
            screens: [display], covered: [display]
        )
        XCTAssertEqual(ids, [id(1)])
    }

    func testAPartiallyVisibleStartCountsAsNotFullyVisible() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): win(-200)], targets: [id(1): win(0)], screens: [display], covered: [display]
        )
        XCTAssertEqual(ids, [id(1)])
    }

    func testStaticAndMovedVisibleWindowsOfTheSameSizeAreNotChecked() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): win(0), id(2): win(500), id(3): win(0.5)],
            targets: [id(1): win(0), id(2): win(100), id(3): win(0)],
            screens: [display], covered: [display]
        )
        XCTAssertEqual(ids, [], "fully visible at the start, same size: it painted before the flight")
    }

    func testWindowsEndingParkedOrOnAnUncoveredDisplayAreNotChecked() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): win(0), id(2): parked], targets: [id(1): parked, id(2): win(1200)],
            screens: [display, other], covered: [display]
        )
        XCTAssertEqual(ids, [], "parked at the end, or landing where no overlay hides it")
    }

    func testAWindowFullyVisibleOnAnotherScreenAtTheStartIsNotChecked() {
        let ids = snapshotPaintCheckWindows(
            starts: [id(1): win(1100)], targets: [id(1): win(100)], screens: [display, other], covered: [display]
        )
        XCTAssertEqual(ids, [])
    }

    func testThePaintCheckCaptureIsNinetySixPixelsWideKeepingTheAspect() {
        XCTAssertTrue(snapshotPaintCheckPixelSize(points: CGSize(width: 1600, height: 900)) == (96, 54))
        XCTAssertTrue(snapshotPaintCheckPixelSize(points: CGSize(width: 400, height: 1200)) == (96, 288))
        XCTAssertTrue(snapshotPaintCheckPixelSize(points: CGSize(width: 2000, height: 10)) == (96, 1))
        XCTAssertTrue(snapshotPaintCheckPixelSize(points: .zero) == (96, 1))
    }

    // MARK: hold policy

    func testNothingToCheckReleasesAtOnceAtDebug() {
        var handoff = SnapshotHandoff()
        let (_, step) = handoff.begin(windows: [], now: 10)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 0, windows: 0, painted: 0, held: false)))
        XCTAssertFalse(handoff.isHolding)
    }

    func testTheHoldStopsWhenEveryWindowPainted() {
        var handoff = SnapshotHandoff()
        let (token, step) = handoff.begin(windows: [id(1), id(2)], now: 10)
        XCTAssertEqual(step, .check([id(1), id(2)]))
        XCTAssertTrue(handoff.isHolding)

        let next = handoff.record(token, verdicts: [id(1): .painted, id(2): .blank], now: 10.012)
        XCTAssertEqual(next, .recheck([id(2)], after: SnapshotHandoff.recheckInterval), "only the unpainted one again")
        XCTAssertTrue(handoff.isHolding)

        let last = handoff.record(token, verdicts: [id(2): .painted], now: 10.054)
        XCTAssertEqual(last, .release(SnapshotHandoffSummary(waitedMilliseconds: 54, windows: 2, painted: 2, held: true)))
        XCTAssertFalse(handoff.isHolding)
        XCTAssertNil(handoff.record(token, verdicts: [id(2): .painted], now: 10.06), "released once")
    }

    func testAllPaintedAtTheFirstCheckIsNoWait() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], now: 10)
        let step = handoff.record(token, verdicts: [id(1): .painted], now: 10.008)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 8, windows: 1, painted: 1, held: false)))
    }

    func testAWindowThatCannotBeCheckedDoesNotHoldTheOverlay() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1), id(2)], now: 10)
        // id(2) missing from the answer: the capture could not see it.
        let step = handoff.record(token, verdicts: [id(1): .unknown], now: 10.01)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 10, windows: 2, painted: 0, held: false)))
    }

    func testTheHoldIsCappedThreeHundredMillisecondsAfterTheDeadline() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], now: 10)
        XCTAssertEqual(SnapshotHandoff.cap, 0.3)
        XCTAssertEqual(handoff.record(token, verdicts: [id(1): .blank], now: 10.1), .recheck([id(1)], after: 0.03))
        XCTAssertNil(handoff.capReached(token, now: 10.29), "not yet")
        let capped = handoff.capReached(token, now: 10.3)
        XCTAssertEqual(capped, SnapshotHandoffSummary(waitedMilliseconds: 300, windows: 1, painted: 0, held: true))
        XCTAssertFalse(handoff.isHolding)
        XCTAssertNil(handoff.capReached(token, now: 10.4), "released once")
    }

    func testACheckAnsweringAfterTheCapReleases() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], now: 10)
        let step = handoff.record(token, verdicts: [id(1): .blank], now: 10.31)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 310, windows: 1, painted: 0, held: true)))
    }

    func testARetargetCancelsTheHoldAndItsLateAnswersAreIgnored() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], now: 10)
        handoff.cancel()
        XCTAssertFalse(handoff.isHolding)
        XCTAssertFalse(handoff.isCurrent(token))
        XCTAssertNil(handoff.record(token, verdicts: [id(1): .painted], now: 10.05))
        XCTAssertNil(handoff.capReached(token, now: 10.4))
        let (next, _) = handoff.begin(windows: [id(1)], now: 11)
        XCTAssertNotEqual(next, token)
        XCTAssertTrue(handoff.isCurrent(next))
    }

    func testTheWatchdogAfterTheDeadlineCoversTheCapPlusAMargin() {
        XCTAssertEqual(SnapshotHandoff.watchdogLimit, SnapshotHandoff.cap + SnapshotHandoff.watchdogMargin)
        XCTAssertGreaterThan(SnapshotHandoff.watchdogMargin, 0)
    }

    // MARK: SM-19 early check

    func testTheEarlyCheckStartsEightyMillisecondsBeforeTheDeadline() {
        XCTAssertEqual(SnapshotHandoff.earlyLead, 0.08)
        XCTAssertEqual(SnapshotHandoff.earlyCheckTime(deadline: 10.3, now: 10), 10.22, accuracy: 1e-9)
        XCTAssertEqual(
            SnapshotHandoff.earlyCheckTime(deadline: 10.05, now: 10), 10,
            "a flight shorter than the lead checks at once"
        )
    }

    func testAnEarlyCheckThatReadPaintedReleasesAtTheDeadline() {
        var handoff = SnapshotHandoff()
        let early = handoff.prepare(windows: [id(1), id(2)])
        XCTAssertEqual(early?.step, .check([id(1), id(2)]))
        let token = early!.token
        XCTAssertTrue(handoff.isCurrent(token))
        XCTAssertFalse(handoff.isHolding, "before the deadline nothing is held")
        XCTAssertNil(handoff.record(token, verdicts: [id(1): .painted, id(2): .unknown], now: 10.25))

        let (landed, step) = handoff.begin(windows: [id(1), id(2)], now: 10.3)
        XCTAssertEqual(landed, token)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 0, windows: 2, painted: 1, held: false)))
        XCTAssertFalse(handoff.isHolding)
    }

    func testAnEarlyBlankHoldsAtTheDeadlineAndChecksOnlyThatWindowAgain() {
        var handoff = SnapshotHandoff()
        let token = handoff.prepare(windows: [id(1), id(2)])!.token
        XCTAssertNil(handoff.record(token, verdicts: [id(1): .painted, id(2): .blank], now: 10.25))

        let (landed, step) = handoff.begin(windows: [id(1), id(2)], now: 10.3)
        XCTAssertEqual(landed, token)
        XCTAssertEqual(step, .check([id(2)]), "held as before: checked now, then every 30 ms")
        XCTAssertTrue(handoff.isHolding)
        let last = handoff.record(token, verdicts: [id(2): .painted], now: 10.32)
        XCTAssertEqual(last, .release(SnapshotHandoffSummary(waitedMilliseconds: 20, windows: 2, painted: 2, held: true)))
    }

    func testAnEarlyCheckStillOutAtTheDeadlineIsAwaitedNotRepeated() {
        var handoff = SnapshotHandoff()
        let token = handoff.prepare(windows: [id(1)])!.token
        let (landed, step) = handoff.begin(windows: [id(1)], now: 10.3)
        XCTAssertEqual(landed, token)
        XCTAssertEqual(step, .awaiting, "its answer continues the hold")
        XCTAssertTrue(handoff.isHolding)
        let answer = handoff.record(token, verdicts: [id(1): .painted], now: 10.31)
        XCTAssertEqual(answer, .release(SnapshotHandoffSummary(waitedMilliseconds: 10, windows: 1, painted: 1, held: false)))
    }

    func testAWindowTheEarlyCheckDidNotCoverIsCheckedAtTheDeadline() {
        var handoff = SnapshotHandoff()
        let early = handoff.prepare(windows: [id(1)])!.token
        let (token, step) = handoff.begin(windows: [id(1), id(2)], now: 10.3)
        XCTAssertNotEqual(token, early, "the early answer would miss id(2): it is dropped")
        XCTAssertEqual(step, .check([id(1), id(2)]))
        XCTAssertNil(handoff.record(early, verdicts: [id(1): .painted], now: 10.31))
    }

    func testARetargetCancelsThePendingEarlyCheckAndANewOneIsPrepared() {
        var handoff = SnapshotHandoff()
        let first = handoff.prepare(windows: [id(1)])!.token
        handoff.cancel()
        XCTAssertFalse(handoff.isCurrent(first))
        XCTAssertNil(handoff.record(first, verdicts: [id(1): .painted], now: 10.2))

        let second = handoff.prepare(windows: [id(1)])!.token
        XCTAssertNotEqual(second, first)
        let (landed, step) = handoff.begin(windows: [id(1)], now: 10.5)
        XCTAssertEqual(landed, second)
        XCTAssertEqual(step, .awaiting, "the cancelled answer did not count")
    }

    func testNothingToCheckEarlyPreparesNothing() {
        var handoff = SnapshotHandoff()
        XCTAssertNil(handoff.prepare(windows: []))
        let (_, step) = handoff.begin(windows: [], now: 10)
        XCTAssertEqual(step, .release(SnapshotHandoffSummary(waitedMilliseconds: 0, windows: 0, painted: 0, held: false)))
    }

    // MARK: SM-19 trust per app

    private func other(_ n: UInt64) -> WindowID { WindowID(pid: 20, elementID: n) }

    func testAnAppIsTrustedAfterFiveCleanChecks() {
        var book = PaintTrustBook()
        XCTAssertEqual(PaintTrustBook.cleanChecksToTrust, 5)
        for _ in 0..<4 {
            book.record([id(1): .painted, id(2): .painted])
        }
        XCTAssertFalse(book.isTrusted(10), "a check with two windows counts once")
        XCTAssertEqual(book.windowsToCheck([id(1), other(1)], holes: []), [id(1), other(1)])
        book.record([id(1): .painted])
        XCTAssertTrue(book.isTrusted(10))
        XCTAssertFalse(book.isTrusted(20))
        XCTAssertEqual(book.windowsToCheck([id(1), id(3), other(1)], holes: []), [other(1)])
    }

    func testABlankMakesATrustedAppCheckedAgain() {
        var book = PaintTrustBook()
        for _ in 0..<5 {
            book.record([id(1): .painted])
        }
        XCTAssertTrue(book.isTrusted(10))
        book.record([id(1): .painted, id(2): .blank])
        XCTAssertFalse(book.isTrusted(10), "any window of the app")
        for _ in 0..<4 {
            book.record([id(1): .painted])
        }
        XCTAssertFalse(book.isTrusted(10), "five clean checks again")
        book.record([id(1): .painted])
        XCTAssertTrue(book.isTrusted(10))
    }

    func testAnUnknownVerdictIsNoEvidence() {
        var book = PaintTrustBook()
        for _ in 0..<5 {
            book.record([id(1): .unknown])
        }
        XCTAssertFalse(book.isTrusted(10))
    }

    func testHoleWindowsAreAlwaysChecked() {
        var book = PaintTrustBook()
        for _ in 0..<5 {
            book.record([id(1): .painted])
        }
        XCTAssertEqual(book.windowsToCheck([id(1), id(2)], holes: [id(2)]), [id(2)])
    }

    // MARK: log line

    func testTheLogLineIsInfoOnlyWhenTheOverlayWasHeld() {
        let held = SnapshotHandoffSummary(waitedMilliseconds: 120, windows: 3, painted: 2, held: true)
        XCTAssertEqual(held.logLine, "snapshot handoff waited ms=120 windows=3 painted=2")
        XCTAssertEqual(held.logLevel, .info)
        let quick = SnapshotHandoffSummary(waitedMilliseconds: 9, windows: 1, painted: 1, held: false)
        XCTAssertEqual(quick.logLine, "snapshot handoff waited ms=9 windows=1 painted=1")
        XCTAssertEqual(quick.logLevel, .debug)
    }
}
