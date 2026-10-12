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
        XCTAssertEqual(book.windowsToCheck([id(1), other(1)], always: []), [id(1), other(1)])
        book.record([id(1): .painted])
        XCTAssertTrue(book.isTrusted(10))
        XCTAssertFalse(book.isTrusted(20))
        XCTAssertEqual(book.windowsToCheck([id(1), id(3), other(1)], always: []), [other(1)])
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
        XCTAssertEqual(book.windowsToCheck([id(1), id(2)], always: [id(2)]), [id(2)])
    }

    // MARK: SM-29 resized windows, partial and stale paints

    func testAResizedWindowIsCheckedEvenWhenItsAppIsTrusted() {
        var book = PaintTrustBook()
        for _ in 0..<5 {
            book.record([id(1): .painted])
        }
        let resized = snapshotResizedWindows(
            starts: [id(1): win(0, width: 400), id(2): win(0), id(3): parked],
            targets: [id(1): win(0, width: 900), id(2): win(300), id(4): win(500)]
        )
        XCTAssertEqual(resized, [id(1)], "a move keeps its size; no start: not known to be resized")
        XCTAssertEqual(book.windowsToCheck([id(1), id(2)], always: resized), [id(1)], "trust skips only the move")
    }

    func testAPartialReadMakesATrustedAppCheckedAgain() {
        var book = PaintTrustBook()
        for _ in 0..<5 {
            book.record([id(1): .painted])
        }
        book.record([id(1): .partial])
        XCTAssertFalse(book.isTrusted(10))
    }

    func testTheRegionAWindowGrewIntoIsItsRightAndBottomStripsInsideTheRimAndCorners() {
        // 800 -> 1600 pt wide, captured 96 x 54: 1 px rim inset, 1 px corners.
        XCTAssertEqual(
            snapshotGrownStrips(
                from: CGSize(width: 800, height: 900), to: CGSize(width: 1600, height: 900), pixelWidth: 96, pixelHeight: 54
            ),
            [CGRect(x: 49, y: 1, width: 46, height: 52)]
        )
        // 300 -> 600 pt high, captured 96 x 144 (top-left origin): corners 3 px.
        XCTAssertEqual(
            snapshotGrownStrips(
                from: CGSize(width: 400, height: 300), to: CGSize(width: 400, height: 600), pixelWidth: 96, pixelHeight: 144
            ),
            [CGRect(x: 3, y: 73, width: 90, height: 70)]
        )
        XCTAssertEqual(
            snapshotGrownStrips(
                from: CGSize(width: 800, height: 450), to: CGSize(width: 1600, height: 900), pixelWidth: 96, pixelHeight: 54
            ).count, 2
        )
    }

    func testNoStripForAShrinkOrAGrowthNarrowerThanAPixel() {
        XCTAssertEqual(
            snapshotGrownStrips(
                from: CGSize(width: 1600, height: 900), to: CGSize(width: 800, height: 900), pixelWidth: 96, pixelHeight: 108
            ), []
        )
        XCTAssertEqual(
            snapshotGrownStrips(
                from: CGSize(width: 1590, height: 900), to: CGSize(width: 1600, height: 900), pixelWidth: 96, pixelHeight: 54
            ), []
        )
    }

    private let black: UInt32 = 0x0000_00FF
    private let sidebar: UInt32 = 0x1818_18FF
    private var sidebarColour: ThemeColor { ThemeColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255) }

    func testAUniformStripUnlikeTheWindowBackgroundIsUnpainted() {
        XCTAssertTrue(snapshotStripUnpainted(samples: Array(repeating: 0, count: 16), background: sidebarColour), "transparent")
        XCTAssertTrue(snapshotStripUnpainted(samples: Array(repeating: black, count: 16), background: sidebarColour))
        XCTAssertTrue(snapshotStripUnpainted(samples: Array(repeating: black, count: 16), background: nil), "black, no background known")
    }

    func testAStripWithContentOrTheWindowBackgroundIsPainted() {
        XCTAssertFalse(snapshotStripUnpainted(samples: Array(repeating: sidebar, count: 16), background: sidebarColour))
        XCTAssertFalse(
            snapshotStripUnpainted(samples: Array(repeating: black, count: 16), background: ThemeColor(red: 0, green: 0, blue: 0)),
            "a black terminal grew into black"
        )
        XCTAssertFalse(snapshotStripUnpainted(samples: Array(repeating: black, count: 15) + [sidebar], background: nil))
        XCTAssertFalse(snapshotStripUnpainted(samples: Array(repeating: sidebar, count: 16), background: nil))
        XCTAssertFalse(snapshotStripUnpainted(samples: [], background: nil), "no samples: no evidence")
    }

    func testAResizedWindowReadsPartialWhenNotYetResizedOrItsGrownStripIsUnpainted() {
        let content = (0..<45).map { UInt32($0) << 8 | 0xFF }
        let probe = SnapshotPaintProbe(
            frame: win(0, width: 900), resizedFrom: CGSize(width: 400, height: 800), background: sidebarColour
        )
        let unpainted = [Array(repeating: black, count: 16)]
        let filled = [Array(repeating: sidebar, count: 15) + [black]]
        func verdict(_ size: CGSize?, _ samples: [UInt32], _ strips: [[UInt32]]) -> SnapshotPaintVerdict {
            snapshotPaintVerdict(probe, windowSize: size, samples: samples, dense: { samples }, strips: strips)
        }
        let target = CGSize(width: 900, height: 800)
        XCTAssertEqual(verdict(CGSize(width: 400, height: 800), content, filled), .partial, "the write has not landed")
        XCTAssertEqual(verdict(target, Array(repeating: black, count: 45), unpainted), .blank)
        XCTAssertEqual(verdict(target, content, unpainted), .partial)
        XCTAssertEqual(verdict(target, content, filled), .painted)
        XCTAssertEqual(verdict(nil, content, filled), .painted, "size unknown: the capture decides")
        XCTAssertEqual(
            verdict(CGSize(width: 700, height: 800), content, filled), .painted,
            "the app chose another size (a minimum): not waiting for the target"
        )
        XCTAssertEqual(
            snapshotPaintVerdict(
                SnapshotPaintProbe(frame: win(0)), windowSize: CGSize(width: 100, height: 100), samples: content,
                dense: { content }, strips: []
            ),
            .painted, "not resized: the SM-14 blank test only"
        )
    }

    func testTwoReadsAreStableWhenAtMostOneSampleInSixteenChanged() {
        let read = (0..<45).map { UInt32($0) << 24 | 0xFF }
        var cursor = read
        cursor[7] = 0xFFFF_FFFF
        cursor[30] = 0xFFFF_FFFF
        XCTAssertTrue(snapshotPaintStable(read, read))
        XCTAssertTrue(snapshotPaintStable(read, cursor), "a blinking cursor")
        var moved = cursor
        moved[12] = 0xFFFF_FFFF
        XCTAssertFalse(snapshotPaintStable(read, moved), "the layout changed")
        var tinted = read
        for index in tinted.indices {
            tinted[index] += 0x0400_0000
        }
        XCTAssertTrue(snapshotPaintStable(read, tinted), "scaling noise")
        XCTAssertFalse(snapshotPaintStable([], []))
        XCTAssertFalse(snapshotPaintStable(read, Array(read.dropLast())))
    }

    private let stale = (0..<45).map { UInt32($0) << 24 | 0xFF }
    private let final = (0..<45).map { UInt32(200 - $0) << 24 | 0xFF }

    func testAPartlyPaintedWindowIsReleasedOnlyAfterTwoMatchingPaintedReads() {
        var handoff = SnapshotHandoff()
        let (token, step) = handoff.begin(windows: [id(1), id(2)], resized: [id(1)], now: 10)
        XCTAssertEqual(step, .check([id(1), id(2)]))
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .partial, id(2): .painted], now: 10.05),
            .recheck([id(1)], after: SnapshotHandoff.recheckInterval)
        )
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.14),
            .recheck([id(1)], after: SnapshotHandoff.recheckInterval),
            "caught repainting: the first painted read may be a stale layout"
        )
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.23),
            .release(SnapshotHandoffSummary(
                waitedMilliseconds: 230, windows: 2, painted: 2, held: true, resized: 1, reason: .partial
            ))
        )
    }

    func testAPaintedReadThatChangedWasStaleAndIsConfirmedAgain() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], resized: [id(1)], now: 10)
        _ = handoff.record(token, verdicts: [id(1): .partial], now: 10.05)
        _ = handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): stale], now: 10.1)
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.15),
            .recheck([id(1)], after: SnapshotHandoff.recheckInterval), "the content changed: not settled yet"
        )
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.2),
            .release(SnapshotHandoffSummary(
                waitedMilliseconds: 200, windows: 1, painted: 1, held: true, resized: 1, reason: .stale
            ))
        )
    }

    func testAnEarlyPartialReadHoldsAtTheDeadlineUntilConfirmed() {
        var handoff = SnapshotHandoff()
        let token = handoff.prepare(windows: [id(1)])!.token
        XCTAssertNil(handoff.record(token, verdicts: [id(1): .partial], now: 10.22))
        let (landed, step) = handoff.begin(windows: [id(1)], resized: [id(1)], now: 10.3)
        XCTAssertEqual(landed, token)
        XCTAssertEqual(step, .check([id(1)]))
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.35),
            .recheck([id(1)], after: SnapshotHandoff.recheckInterval)
        )
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.4),
            .release(SnapshotHandoffSummary(
                waitedMilliseconds: 100, windows: 1, painted: 1, held: true, resized: 1, reason: .partial
            ))
        )
    }

    func testAPaintedReadWithoutSamplesCannotBeConfirmedAndReleases() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], resized: [id(1)], now: 10)
        _ = handoff.record(token, verdicts: [id(1): .partial], now: 10.05)
        XCTAssertEqual(
            handoff.record(token, verdicts: [id(1): .painted], now: 10.1),
            .release(SnapshotHandoffSummary(
                waitedMilliseconds: 100, windows: 1, painted: 1, held: true, resized: 1, reason: .partial
            ))
        )
    }

    func testAResizedWindowPaintedAtOnceNeedsNoConfirmation() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], resized: [id(1)], now: 10)
        let step = handoff.record(token, verdicts: [id(1): .painted], samples: [id(1): final], now: 10.008)
        let summary = SnapshotHandoffSummary(waitedMilliseconds: 8, windows: 1, painted: 1, held: false, resized: 1)
        XCTAssertEqual(step, .release(summary))
        XCTAssertEqual(summary.logLevel, .debug)
        XCTAssertEqual(summary.logLine, "snapshot handoff waited ms=8 windows=1 painted=1 resized=1")
    }

    func testTheCapReleasesAWindowStillRepainting() {
        var handoff = SnapshotHandoff()
        let (token, _) = handoff.begin(windows: [id(1)], resized: [id(1)], now: 10)
        _ = handoff.record(token, verdicts: [id(1): .partial], now: 10.05)
        XCTAssertEqual(
            handoff.capReached(token, now: 10.3),
            SnapshotHandoffSummary(waitedMilliseconds: 300, windows: 1, painted: 0, held: true, resized: 1, reason: .partial)
        )
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

    func testTheLogLineNamesResizedWindowsAndWhatHeldThem() {
        let partial = SnapshotHandoffSummary(
            waitedMilliseconds: 230, windows: 2, painted: 2, held: true, resized: 1, reason: .partial
        )
        XCTAssertEqual(partial.logLine, "snapshot handoff waited ms=230 windows=2 painted=2 resized=1 held=partial")
        XCTAssertEqual(partial.logLevel, .info)
        let stale = SnapshotHandoffSummary(waitedMilliseconds: 200, windows: 1, painted: 1, held: true, resized: 1, reason: .stale)
        XCTAssertEqual(stale.logLine, "snapshot handoff waited ms=200 windows=1 painted=1 resized=1 held=stale")
    }
}
