import CoreGraphics
import XCTest
@testable import GioCore

/// FI-16: a window that is on screen but was never registered (its app's
/// Accessibility was not ready during the scans) is rescanned with backoff
/// until it is registered, the window server stops listing it or its app
/// dies; a window that never becomes manageable is given up and remembered.
final class StrandedWindowRetryTests: XCTestCase {
    func testTheBackoffIsShortThenLonger() {
        XCTAssertEqual(StrandedWindowRetry.delays, [0.5, 1.5, 4, 10])
        XCTAssertEqual(StrandedWindowRetry.auditInterval, 30)
        XCTAssertEqual(StrandedWindowRetry.wakeSettleDelays, [2, 6])
    }

    func testARequestStartsOneSeriesPerPid() {
        var book = StrandedWindowRetryBook()
        XCTAssertEqual(
            book.request(7, reason: .unregistered),
            WindowRetryStep(pid: 7, attempt: 1, delay: 0.5, reason: .unregistered)
        )
        XCTAssertNil(book.request(7, reason: .unregistered), "one series per pid")
        XCTAssertTrue(book.isPending(7, attempt: 1))
        XCTAssertFalse(book.isPending(7, attempt: 2))
        XCTAssertEqual(book.request(8, reason: .skipped)?.attempt, 1)
    }

    func testAnUnresolvedAttemptBacksOffThenGivesUp() {
        var book = StrandedWindowRetryBook()
        _ = book.request(7, reason: .skipped)
        var steps: [WindowRetryOutcome] = []
        for attempt in 1...4 {
            steps.append(book.finish(7, attempt: attempt, alive: true, resolved: false, stranded: []))
        }
        XCTAssertEqual(steps, [
            .retry(WindowRetryStep(pid: 7, attempt: 2, delay: 1.5, reason: .skipped)),
            .retry(WindowRetryStep(pid: 7, attempt: 3, delay: 4, reason: .skipped)),
            .retry(WindowRetryStep(pid: 7, attempt: 4, delay: 10, reason: .skipped)),
            .gaveUp(attempts: 4, reason: .skipped),
        ])
        XCTAssertFalse(book.isPending(7, attempt: 4))
    }

    func testAResolvedOrDeadAppEndsTheSeries() {
        var book = StrandedWindowRetryBook()
        _ = book.request(7, reason: .unregistered)
        XCTAssertEqual(book.finish(7, attempt: 1, alive: true, resolved: true, stranded: []), .resolved)
        XCTAssertFalse(book.isPending(7, attempt: 1))
        XCTAssertEqual(book.request(7, reason: .unregistered)?.attempt, 1, "a later request starts over")
        XCTAssertEqual(book.finish(7, attempt: 1, alive: false, resolved: false, stranded: [41]), .appGone)
        XCTAssertTrue(book.rejected.isEmpty, "a dead app's windows are not remembered")
    }

    func testAnUnregisteredRequestUpgradesASkippedSeries() {
        var book = StrandedWindowRetryBook()
        _ = book.request(7, reason: .skipped)
        XCTAssertNil(book.request(7, reason: .unregistered))
        XCTAssertEqual(
            book.finish(7, attempt: 1, alive: true, resolved: false, stranded: [41]),
            .retry(WindowRetryStep(pid: 7, attempt: 2, delay: 1.5, reason: .unregistered))
        )
    }

    func testGivingUpRemembersTheStrandedNumbersUntilTheyLeave() {
        var book = StrandedWindowRetryBook()
        _ = book.request(7, reason: .unregistered)
        for attempt in 1...4 {
            _ = book.finish(7, attempt: attempt, alive: true, resolved: false, stranded: [41, 42])
        }
        XCTAssertEqual(book.rejected, [41, 42])
        book.keepRejected(listed: [42, 99])
        XCTAssertEqual(book.rejected, [42], "a number the window server dropped is forgotten")
        book.clearRejected()
        XCTAssertTrue(book.rejected.isEmpty)
    }

    /// An element whose attributes never answer must not restart a series on
    /// every full scan: after giving up, skips of that pid wait until one of
    /// its scans reads it fully again.
    func testASkipSeriesThatGaveUpWaitsForAFullRead() {
        var book = StrandedWindowRetryBook()
        _ = book.request(7, reason: .skipped)
        for attempt in 1...4 {
            _ = book.finish(7, attempt: attempt, alive: true, resolved: false, stranded: [])
        }
        XCTAssertNil(book.request(7, reason: .skipped))
        XCTAssertEqual(book.request(7, reason: .unregistered)?.attempt, 1, "a stranded window still asks")
        _ = book.finish(7, attempt: 1, alive: true, resolved: true, stranded: [])
        book.noteRead(7, complete: false)
        XCTAssertNil(book.request(7, reason: .skipped))
        book.noteRead(7, complete: true)
        XCTAssertEqual(book.request(7, reason: .skipped)?.attempt, 1)
    }

    // MARK: Window server vs registry

    private func window(_ pid: pid_t, _ number: UInt32?) -> ServerWindow {
        ServerWindow(pid: pid, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), number: number)
    }

    func testUnregisteredWindowsOfManageableAppsAreStranded() {
        let stranded = strandedServerWindows(
            [window(7, 8530), window(7, 41), window(8, 50), window(7, 8531)],
            registeredNumbers: [41, 50], ownPID: 1, manageablePIDs: [7, 8], rejected: []
        )
        XCTAssertEqual(stranded, [7: [8530, 8531]])
    }

    func testGiosOwnAgentsAndRejectedWindowsAreNeverStranded() {
        let stranded = strandedServerWindows(
            [window(1, 10), window(412, 11), window(7, 12), window(7, nil), window(8, 13)],
            registeredNumbers: [], ownPID: 1, manageablePIDs: [1, 7, 8], rejected: [12]
        )
        XCTAssertEqual(stranded, [8: [13]], "own pid, non-regular pids, rejected and numberless windows are left out")
    }
}
