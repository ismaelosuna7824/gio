import Foundation
import GioCore
import XCTest

/// NW-06: `when-active` follows an arrival whose app is frontmost, was
/// launched moments ago, or becomes active just after its window was placed
/// (unless the user moved in the meantime). `always` and `never` ignore
/// timing. Pure: explicit clock values, no desktop.
final class ArrivalFollowTests: XCTestCase {
    private let window = WindowID(pid: 7, elementID: 1)
    private let named = WorkspaceID(10)
    private let here = WorkspaceID(3)

    // MARK: Decision at registration

    func testFrontmostAppFollows() {
        XCTAssertEqual(
            decideArrivalFollow(.whenActive, windowPID: 7, frontmostPID: 7, launchedAt: nil, now: 5),
            .follow(.frontmost)
        )
    }

    func testRecentlyLaunchedAppFollowsEvenWhenNotFrontmost() {
        XCTAssertEqual(
            decideArrivalFollow(.whenActive, windowPID: 7, frontmostPID: 99, launchedAt: 3, now: 5),
            .follow(.launched)
        )
        XCTAssertEqual(
            decideArrivalFollow(.whenActive, windowPID: 7, frontmostPID: 99, launchedAt: 2, now: 5),
            .follow(.launched), "3 s is still recent"
        )
    }

    func testAnOldLaunchOrNoneWaitsForActivation() {
        XCTAssertEqual(
            decideArrivalFollow(.whenActive, windowPID: 7, frontmostPID: 99, launchedAt: 1, now: 5),
            .pending
        )
        XCTAssertEqual(
            decideArrivalFollow(.whenActive, windowPID: 7, frontmostPID: nil, launchedAt: nil, now: 5),
            .pending
        )
    }

    func testAlwaysAndNeverIgnoreTiming() {
        XCTAssertEqual(
            decideArrivalFollow(.always, windowPID: 7, frontmostPID: 99, launchedAt: nil, now: 5), .follow(.always)
        )
        XCTAssertEqual(decideArrivalFollow(.never, windowPID: 7, frontmostPID: 7, launchedAt: 5, now: 5), .stay)
    }

    // MARK: Recent launches

    func testRecentLaunchesForgetOldEntries() {
        var launches = RecentLaunches()
        launches.record(7, at: 1)
        XCTAssertEqual(launches.launchedAt(7, now: 3.9), 1)
        XCTAssertNil(launches.launchedAt(7, now: 4.1))
        XCTAssertNil(launches.launchedAt(8, now: 1))
        launches.record(9, at: 10)
        XCTAssertEqual(launches.count, 1, "stale launches are pruned on record")
    }

    // MARK: Pending follows

    private func pending(_ id: WindowID, at time: TimeInterval) -> PendingArrivalFollow {
        PendingArrivalFollow(id: id, workspace: named, placedAt: time, fromWorkspace: here, fromFocus: nil)
    }

    func testActivationWithinTheWindowConsumesTheNewestPendingFollow() {
        var book = PendingFollowBook()
        let older = WindowID(pid: 7, elementID: 2)
        book.add(pending(older, at: 0.5))
        book.add(pending(window, at: 1))
        XCTAssertEqual(book.activated(pid: 7, now: 2)?.id, window)
        XCTAssertNil(book.activated(pid: 7, now: 2), "consumed with every other entry of the app")
        XCTAssertEqual(book.count, 0)
    }

    func testActivationAfterTheDeadlineFollowsNothing() {
        var book = PendingFollowBook()
        book.add(pending(window, at: 1))
        XCTAssertNil(book.activated(pid: 7, now: 2.6))
        XCTAssertEqual(book.count, 0, "expired entries are dropped")
    }

    func testAnotherAppsActivationLeavesThePendingFollow() {
        var book = PendingFollowBook()
        book.add(pending(window, at: 1))
        XCTAssertNil(book.activated(pid: 8, now: 1.2))
        XCTAssertEqual(book.activated(pid: 7, now: 1.3)?.id, window)
    }

    func testAClosedWindowIsForgotten() {
        var book = PendingFollowBook()
        book.add(pending(window, at: 1))
        book.forget(window)
        XCTAssertNil(book.activated(pid: 7, now: 1.1))
    }

    func testTheUserMovingMeanwhileCancels() {
        let focus = WindowID(pid: 3, elementID: 1)
        let record = PendingArrivalFollow(id: window, workspace: named, placedAt: 1, fromWorkspace: here, fromFocus: focus)
        XCTAssertTrue(pendingFollowStillWanted(record, currentWorkspace: here, currentFocus: focus))
        XCTAssertFalse(pendingFollowStillWanted(record, currentWorkspace: WorkspaceID(4), currentFocus: focus))
        XCTAssertFalse(pendingFollowStillWanted(
            record, currentWorkspace: here, currentFocus: WindowID(pid: 3, elementID: 2)
        ))
        XCTAssertFalse(pendingFollowStillWanted(record, currentWorkspace: named, currentFocus: focus), "already there")
    }
}
