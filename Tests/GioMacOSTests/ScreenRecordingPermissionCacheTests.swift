import Foundation
@testable import GioMacOS
import XCTest

/// PF-X: `CGPreflightScreenCaptureAccess` is an IPC to tccd (~8 ms per call,
/// measured 2026-10-15) and the snapshot path asked it several times per
/// typing hop and per capture run on the session queue.
final class ScreenRecordingPermissionCacheTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var answers: [Bool] = []
    private var checks = 0

    private func makeCache() -> ScreenRecordingPermissionCache {
        ScreenRecordingPermissionCache(
            check: { [unowned self] in
                checks += 1
                return answers.isEmpty ? true : answers.removeFirst()
            },
            now: { [unowned self] in clock }
        )
    }

    func testAnswersFromTheCacheUntilTheTimeToLiveEnds() {
        let cache = makeCache()
        answers = [true, false]
        XCTAssertTrue(cache.granted())
        clock += ScreenRecordingPermissionCache.ttl - 0.1
        XCTAssertTrue(cache.granted())
        XCTAssertEqual(checks, 1)

        clock += 0.2
        XCTAssertFalse(cache.granted(), "a revoke is seen once the cached answer expired")
        XCTAssertEqual(checks, 2)
    }

    func testRefreshAsksNowAndUpdatesTheCachedAnswer() {
        let cache = makeCache()
        answers = [true, false]
        XCTAssertTrue(cache.granted())
        XCTAssertFalse(cache.refresh())
        XCTAssertFalse(cache.granted())
        XCTAssertEqual(checks, 2)
    }
}
