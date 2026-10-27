import CoreGraphics
import XCTest
@testable import GioCore

/// PF-AP/PF-AS: the overview takes its first thumbnails from the snapshot
/// cache (scaled down before they reach the panel) and captures only the
/// windows without a fresh image of their current size.
final class OverviewThumbnailPlanTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    /// A full-resolution image of `frame` on a 2x display.
    private var fullPixels: Int { 1600 * 1200 }

    func testFreshMatchingEntryIsReused() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: fullPixels, at: 100)
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: cache, now: 110)
        XCTAssertEqual(plan.fromCache, [id(1): "a"])
        XCTAssertTrue(plan.toCapture.isEmpty)
    }

    func testEntryWithinSizeToleranceAndMovedIsReused() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: fullPixels, at: 100)
        let moved = CGRect(x: 900, y: 40, width: 801, height: 599)
        let plan = overviewThumbnailPlan(windows: [id(1): moved], cache: cache, now: 110)
        XCTAssertEqual(plan.fromCache, [id(1): "a"])
        XCTAssertTrue(plan.toCapture.isEmpty)
    }

    func testStaleEntryIsCaptured() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: fullPixels, at: 100)
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: cache, now: 100 + snapshotSoftAge + 1)
        XCTAssertTrue(plan.fromCache.isEmpty)
        XCTAssertEqual(plan.toCapture, [id(1): frame])
    }

    func testSizeMismatchIsCaptured() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: fullPixels, at: 100)
        let wider = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let plan = overviewThumbnailPlan(windows: [id(1): wider], cache: cache, now: 110)
        XCTAssertTrue(plan.fromCache.isEmpty)
        XCTAssertEqual(plan.toCapture, [id(1): wider])
    }

    func testMissingEntryIsCaptured() {
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: SnapshotCache<String>(), now: 110)
        XCTAssertTrue(plan.fromCache.isEmpty)
        XCTAssertEqual(plan.toCapture, [id(1): frame])
    }

    /// The other kept size (SM-11) does not stand in for the current one.
    func testFreshImageOfTheOtherSizeOnlyIsCaptured() {
        var cache = SnapshotCache<String>()
        let wider = CGRect(x: 0, y: 0, width: 1200, height: 600)
        cache.store(id(1), image: "old", frame: frame, pixels: fullPixels, at: 100)
        cache.store(id(1), image: "wide", frame: wider, pixels: 2400 * 1200, at: 105)
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: cache, now: 140)
        XCTAssertTrue(plan.fromCache.isEmpty, "the image of the current size is past the soft age")
        XCTAssertEqual(plan.toCapture, [id(1): frame])
    }

    /// A half-resolution image on a 1x display (0.5 px/pt) is coarser than a
    /// thumbnail capture (`minPixelsPerPoint`): captured again.
    func testEntryBelowTheThumbnailResolutionIsCaptured() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 400 * 300, at: 100, resolution: .half)
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: cache, now: 110, minPixelsPerPoint: 0.75)
        XCTAssertTrue(plan.fromCache.isEmpty)
        XCTAssertEqual(plan.toCapture, [id(1): frame])
    }

    func testHalfResolutionOnARetinaDisplayIsReused() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 800 * 600, at: 100, resolution: .half)
        let plan = overviewThumbnailPlan(windows: [id(1): frame], cache: cache, now: 110, minPixelsPerPoint: 0.75)
        XCTAssertEqual(plan.fromCache, [id(1): "a"])
    }

    /// The ax renderer keeps no images: everything is captured, as before PF-AP.
    func testEmptyCacheCapturesEveryWindow() {
        let windows = [id(1): frame, id(2): frame.offsetBy(dx: 900, dy: 0)]
        let plan = overviewThumbnailPlan(windows: windows, cache: SnapshotCache<String>(), now: 110)
        XCTAssertTrue(plan.fromCache.isEmpty)
        XCTAssertEqual(plan.toCapture, windows)
    }

    func testMixedSetSplitsBetweenCacheAndCapture() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: fullPixels, at: 100)
        cache.store(id(2), image: "b", frame: frame, pixels: fullPixels, at: 50)
        let windows = [id(1): frame, id(2): frame, id(3): frame]
        let plan = overviewThumbnailPlan(windows: windows, cache: cache, now: 110)
        XCTAssertEqual(plan.fromCache, [id(1): "a"])
        XCTAssertEqual(plan.toCapture, [id(2): frame, id(3): frame])
    }

    func testLogLineCountsAndMillisecondsOnly() {
        XCTAssertEqual(
            overviewThumbnailsLogLine(cached: 5, captured: 2, scaleMilliseconds: 3),
            "overview thumbnails cached=5 capture=2 scaleMs=3"
        )
    }
}
