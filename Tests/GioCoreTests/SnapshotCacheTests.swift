import CoreGraphics
import XCTest
@testable import GioCore

/// SM-04: bookkeeping of the pre-captured snapshot cache (images are opaque
/// generic values here; the app stores CGImages).
final class SnapshotCacheTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testStoresAndReturnsAnEntryWithItsCaptureTimeAndFrame() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 100, at: 5)
        let entry = cache.entry(id(1))
        XCTAssertEqual(entry?.image, "a")
        XCTAssertEqual(entry?.frame, frame)
        XCTAssertEqual(entry?.capturedAt, 5)
        XCTAssertEqual(cache.totalPixels, 100)
    }

    func testStoringAgainReplacesTheEntryAndItsPixels() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 100, at: 1)
        cache.store(id(1), image: "b", frame: frame, pixels: 40, at: 2)
        XCTAssertEqual(cache.entry(id(1))?.image, "b")
        XCTAssertEqual(cache.totalPixels, 40)
        XCTAssertEqual(cache.count, 1)
    }

    func testRetainDropsWindowsThatAreGoneOrMinimized() {
        var cache = SnapshotCache<String>()
        for n in 1...3 { cache.store(id(UInt64(n)), image: "i\(n)", frame: frame, pixels: 10, at: 1) }
        let dropped = cache.retain(only: [id(2)])
        XCTAssertEqual(Set(dropped), [id(1), id(3)])
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalPixels, 10)
    }

    func testEnforceEvictsLeastRecentlyUsedFirstUntilUnderTheCap() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "b", frame: frame, pixels: 60, at: 2)
        cache.store(id(3), image: "c", frame: frame, pixels: 60, at: 3)
        cache.touch([id(1)], at: 10)   // 1 is now the freshest
        let evicted = cache.enforce(capPixels: 130)
        XCTAssertEqual(evicted, [id(2)])
        XCTAssertNotNil(cache.entry(id(1)))
        XCTAssertNotNil(cache.entry(id(3)))
        XCTAssertLessThanOrEqual(cache.totalPixels, 130)
    }

    func testEnforceKeepsEverythingWhenUnderTheCap() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        XCTAssertEqual(cache.enforce(capPixels: 60), [])
    }

    func testCapIsTwelveDisplaysOfPixels() {
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: 1000), 12_000)
    }

    func testEntryIsUsableWhileFreshAndTheSizeStillMatches() {
        let entry = SnapshotCacheEntry(image: "a", frame: frame, capturedAt: 100, lastUsed: 100, pixels: 1)
        XCTAssertTrue(snapshotEntryUsable(entry, currentFrame: frame.offsetBy(dx: 900, dy: 0), now: 130, maxAge: 60))
        XCTAssertFalse(snapshotEntryUsable(entry, currentFrame: frame, now: 161, maxAge: 60))
        XCTAssertFalse(snapshotEntryUsable(
            entry, currentFrame: CGRect(x: 0, y: 0, width: 700, height: 600), now: 101, maxAge: 60
        ))
        XCTAssertTrue(snapshotEntryUsable(
            entry, currentFrame: CGRect(x: 0, y: 0, width: 801, height: 599), now: 101, maxAge: 60
        ))
    }

    func testAgeInMillisecondsOfTheOldestUsedEntry() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 1, at: 10)
        cache.store(id(2), image: "b", frame: frame, pixels: 1, at: 12)
        XCTAssertEqual(cache.maxAgeMilliseconds(of: [id(1), id(2)], now: 12.5), 2500)
        XCTAssertEqual(cache.maxAgeMilliseconds(of: [], now: 12.5), 0)
    }

    // MARK: capture set

    func testCaptureSetIsVisibleThenTheAdjacentColumnsThenExtras() {
        let columns: [[WindowID]] = [[id(1)], [id(2), id(3)], [id(4)], [id(5)], [id(6)]]
        let set = snapshotCaptureSet(columns: columns, visible: [id(3), id(4)], extras: [id(9)])
        // visible columns 1..2 in column order, then left neighbour, right neighbour, extras.
        XCTAssertEqual(set, [id(2), id(3), id(4), id(1), id(5), id(9)])
    }

    func testCaptureSetAtTheEdgeHasNoMissingNeighbour() {
        let columns: [[WindowID]] = [[id(1)], [id(2)]]
        XCTAssertEqual(snapshotCaptureSet(columns: columns, visible: [id(1)], extras: []), [id(1), id(2)])
    }

    func testCaptureSetWithNothingVisibleIsOnlyTheExtras() {
        XCTAssertEqual(snapshotCaptureSet(columns: [[id(1)]], visible: [], extras: [id(7)]), [id(7)])
    }

    func testCaptureSetHasNoDuplicates() {
        let columns: [[WindowID]] = [[id(1)], [id(2)]]
        XCTAssertEqual(snapshotCaptureSet(columns: columns, visible: [id(1)], extras: [id(2), id(1)]), [id(1), id(2)])
    }
}
