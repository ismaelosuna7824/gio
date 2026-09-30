import XCTest
@testable import GioCore

/// Conservative render verification: `ws=missing` only when nothing of the
/// app is drawn where the window should be; ambiguity and edge columns are
/// unknown (no nudge); a failed nudge is never repeated.
final class RenderConservativeTests: XCTestCase {
    private func id(_ pid: pid_t, _ element: UInt64 = 1) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private let column = CGRect(x: 912, y: 8, width: 888, height: 1114)

    private func evaluate(
        ax: [WindowID: CGRect], server: [ServerWindow]
    ) -> RenderVerdict {
        evaluateRender(axFrames: ax, server: server, targets: ax, viewports: [viewport])
    }

    func testChromeWithSeveralSameSizeWindowsElsewhereIsNotMissing() {
        // Two other Chrome windows of the same size, none at the column.
        let server = [
            ServerWindow(pid: 5, bounds: column.offsetBy(dx: -900, dy: 0)),
            ServerWindow(pid: 5, bounds: column.offsetBy(dx: -1800, dy: 0)),
            ServerWindow(pid: 5, bounds: CGRect(x: 950, y: 40, width: 700, height: 500)),
        ]
        let verdict = evaluate(ax: [id(5): column], server: server)
        XCTAssertEqual(verdict.mismatches.filter { $0.ws == nil }, [])
    }

    func testDifferentSizeEntryOverlappingTheColumnIsUnknownNotMissing() {
        let drawn = CGRect(x: 912, y: 8, width: 400, height: 1114)
        let verdict = evaluate(ax: [id(5): column], server: [ServerWindow(pid: 5, bounds: drawn)])
        XCTAssertEqual(verdict.mismatches, [])
        XCTAssertEqual(verdict.unmatched, [RenderUnmatched(id: id(5), reason: .overlapsOther, candidates: 1)])
    }

    func testSeveralCandidatesAreAmbiguousAndReported() {
        let a = column.offsetBy(dx: -300, dy: 0)
        let b = column.offsetBy(dx: -500, dy: 0)
        let verdict = evaluate(ax: [id(5): column], server: [ServerWindow(pid: 5, bounds: a), ServerWindow(pid: 5, bounds: b)])
        XCTAssertEqual(verdict.mismatches, [])
        XCTAssertEqual(verdict.unmatched, [RenderUnmatched(id: id(5), reason: .ambiguous, candidates: 2)])
    }

    func testEdgeWindowMostlyOffScreenIsSkipped() {
        let edge = CGRect(x: 1791, y: 8, width: 888, height: 1114)
        let verdict = evaluate(ax: [id(7): edge], server: [])
        XCTAssertEqual(verdict.mismatches, [])
        XCTAssertEqual(verdict.unmatched, [RenderUnmatched(id: id(7), reason: .offscreenTarget, candidates: 0)])
    }

    func testLeftPeekWindowIsSkipped() {
        let peek = CGRect(x: -961, y: 8, width: 970, height: 1114)
        let verdict = evaluate(ax: [id(7): peek], server: [])
        XCTAssertEqual(verdict.mismatches, [])
        XCTAssertEqual(verdict.unmatched.map(\.reason), [.offscreenTarget])
    }

    func testHalfVisibleWindowIsStillChecked() {
        let half = CGRect(x: 900, y: 8, width: 1800, height: 1114)
        let verdict = evaluate(ax: [id(7): half], server: [])
        XCTAssertEqual(verdict.mismatches, [RenderMismatch(id: id(7), ax: half, ws: nil)])
    }

    func testGenuinelyAbsentPidIsMissing() {
        let verdict = evaluate(ax: [id(5): column], server: [ServerWindow(pid: 9, bounds: column)])
        XCTAssertEqual(verdict.mismatches, [RenderMismatch(id: id(5), ax: column, ws: nil)])
        XCTAssertEqual(verdict.unmatched, [])
    }

    func testPidDrawnOnlyFarFromTheTargetIsMissing() {
        let far = CGRect(x: 0, y: 8, width: 300, height: 400)
        let verdict = evaluate(ax: [id(5): column], server: [ServerWindow(pid: 5, bounds: far)])
        XCTAssertEqual(verdict.mismatches, [RenderMismatch(id: id(5), ax: column, ws: nil)])
    }

    func testMinimumSizeAcceptedFrameMatches() {
        // The reconciler settled on 970 wide (learned minimum); the server draws 970.
        let settled = CGRect(x: 900, y: 8, width: 900, height: 1114)
        let verdict = evaluate(ax: [id(5): settled], server: [ServerWindow(pid: 5, bounds: settled)])
        XCTAssertEqual(verdict.mismatches, [])
        XCTAssertEqual(verdict.unmatched, [])
    }

    func testSameSizeStaleWindowIsStillARealMismatch() {
        let stale = column.offsetBy(dx: -880, dy: 0)
        let verdict = evaluate(ax: [id(5): column], server: [ServerWindow(pid: 5, bounds: stale)])
        XCTAssertEqual(verdict.mismatches, [RenderMismatch(id: id(5), ax: column, ws: stale)])
    }

    func testUnmatchedLineExplainsTheReason() {
        XCTAssertEqual(
            renderUnmatchedLine(id: id(5, 11), app: "Google Chrome", reason: .ambiguous, candidates: 3),
            "render unmatched id=5:11 app=Google Chrome reason=ambiguous candidates=3"
        )
    }

    // MARK: Nudge budget

    func testFailedNudgeMarksTheWindowUnverifiableOnceAndStopsChecking() {
        var book = RenderCheckBook()
        _ = book.schedule()
        XCTAssertEqual(book.claimNudges([id(1)]), [id(1)])
        XCTAssertTrue(book.recordNudge(id(1), fixed: false))
        XCTAssertFalse(book.recordNudge(id(1), fixed: false))
        XCTAssertTrue(book.isUnverifiable(id(1)))
        _ = book.schedule()
        XCTAssertEqual(book.claimNudges([id(1), id(2)]), [id(2)])
        XCTAssertEqual(book.checkable([id(1): column, id(2): column]).keys.sorted(), [id(2)])
    }

    func testFixedNudgeKeepsTheWindowCheckable() {
        var book = RenderCheckBook()
        _ = book.schedule()
        XCTAssertFalse(book.recordNudge(id(1), fixed: true))
        XCTAssertFalse(book.isUnverifiable(id(1)))
    }

    func testForgettingAWindowRestoresChecking() {
        var book = RenderCheckBook()
        _ = book.recordNudge(id(1), fixed: false)
        book.forget([id(1)])
        XCTAssertFalse(book.isUnverifiable(id(1)))
    }
}
