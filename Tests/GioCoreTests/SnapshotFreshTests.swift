import CoreGraphics
import XCTest
@testable import GioCore

/// SM-30: a resized window is captured again at its target size during the
/// flight, once its write had time to land, and the layer fades to that
/// fresh image (and the cache keeps it). A read the app has not repainted
/// for yet (wrong size, blank, unpainted grown strip, or its old layout
/// clipped to the new frame) is retried within a bound, and after such a read
/// two matching reads are needed. Resized windows fade out at the hand-off.
final class SnapshotFreshTests: XCTestCase {
    private let id = WindowID(pid: 13261, elementID: 4)
    private let half = CGSize(width: 800, height: 900)
    private let maximized = CGSize(width: 1600, height: 900)
    private let layoutA: [UInt32] = (0..<45).map { UInt32($0) << 24 | 0xFF }
    private let layoutB: [UInt32] = (0..<45).map { UInt32(200 - $0) << 16 | 0xFF }

    private func read(
        paint: SnapshotPaintVerdict = .painted, windowSize: CGSize? = nil, samples: [UInt32]? = nil,
        startRegion: [UInt32]? = nil, freshRegion: [UInt32]? = nil, cached: [UInt32]? = nil
    ) -> SnapshotFreshRead<String> {
        SnapshotFreshRead(
            image: "fresh", fill: nil, windowSize: windowSize, paint: paint, samples: samples ?? layoutA,
            startRegion: startRegion, freshRegion: freshRegion, cached: cached
        )
    }

    // MARK: region compared for staleness

    /// Live (VS Code, max to half): ~370 ms after the resize the window still
    /// showed its maximized layout clipped to the half frame. That is the
    /// start image cut to what both sizes share; a grow keeps the old layout
    /// at the top-left too, but the SM-29 strip test already sees it.
    func testTheRegionComparedIsWhatBothSizesShareAndOnlyWhenTheWindowShrank() {
        XCTAssertEqual(snapshotFreshRegion(start: maximized, target: half), half)
        XCTAssertEqual(
            snapshotFreshRegion(start: CGSize(width: 1600, height: 900), target: CGSize(width: 1800, height: 600)),
            CGSize(width: 1600, height: 600), "shorter: the shared top-left part"
        )
        XCTAssertNil(snapshotFreshRegion(start: half, target: maximized), "a grow: the grown strips decide")
        XCTAssertNil(snapshotFreshRegion(start: half, target: CGSize(width: 799.5, height: 900)), "within a point")
    }

    func testTheRegionInImagePixelsHangsFromTheTopLeftCorner() {
        XCTAssertEqual(
            snapshotRegionPixels(half, of: maximized, pixelWidth: 3200, pixelHeight: 1800),
            CGRect(x: 0, y: 0, width: 1600, height: 1800)
        )
        XCTAssertEqual(
            snapshotRegionPixels(CGSize(width: 800, height: 450), of: maximized, pixelWidth: 800, pixelHeight: 450),
            CGRect(x: 0, y: 0, width: 400, height: 225), "a half-resolution image"
        )
    }

    // MARK: verdict of one read

    func testAReadNotAtTheTargetSizeOrNotPaintedIsNotFresh() {
        XCTAssertEqual(snapshotFreshVerdict(read(), target: half), .fresh)
        XCTAssertEqual(
            snapshotFreshVerdict(read(windowSize: maximized), target: half), .partial,
            "the WindowServer still reports another size: the capture would be scaled"
        )
        XCTAssertEqual(snapshotFreshVerdict(read(windowSize: CGSize(width: 801, height: 899)), target: half), .fresh)
        XCTAssertEqual(snapshotFreshVerdict(read(paint: .partial), target: half), .partial)
        XCTAssertEqual(snapshotFreshVerdict(read(paint: .blank), target: half), .blank)
        XCTAssertEqual(snapshotFreshVerdict(read(paint: .unknown), target: half), .unknown)
        XCTAssertEqual(snapshotFreshVerdict(nil as SnapshotFreshRead<String>?, target: half), .unknown, "no match, no capture")
    }

    func testAPaintedReadStillShowingTheClippedOldLayoutIsStale() {
        XCTAssertEqual(
            snapshotFreshVerdict(read(startRegion: layoutA, freshRegion: layoutA), target: half), .stale
        )
        XCTAssertEqual(
            snapshotFreshVerdict(read(startRegion: layoutA, freshRegion: layoutB), target: half), .fresh,
            "re-laid out: its right edge, corners and wrapped content differ"
        )
    }

    /// A terminal's top-left content looks the same before and after; when
    /// the read matches the cached image of the target size it is right.
    func testAReadMatchingTheCachedTargetImageIsFreshEvenIfTheOldLayoutMatchesToo() {
        XCTAssertEqual(
            snapshotFreshVerdict(read(startRegion: layoutA, freshRegion: layoutA, cached: layoutA), target: half), .fresh
        )
        XCTAssertEqual(
            snapshotFreshVerdict(read(startRegion: layoutA, freshRegion: layoutA, cached: layoutB), target: half), .stale
        )
    }

    // MARK: tracker

    func testTheFirstCaptureRunsAfterTheWriteHadTimeToLandAndAFreshReadApplies() {
        var tracker = SnapshotFreshTracker()
        XCTAssertEqual(SnapshotFreshTracker.firstDelay, 0.12)
        let token = tracker.start(id, now: 10)
        XCTAssertTrue(tracker.capture(id, token: token))
        XCTAssertEqual(tracker.record(id, token: token, verdict: .fresh, samples: layoutA, now: 10.2), .apply)
        XCTAssertEqual(tracker.outcome(id), SnapshotFreshOutcome(milliseconds: 200, attempts: 1, last: .fresh))
        XCTAssertFalse(tracker.capture(id, token: token), "done: no more captures")
        XCTAssertNil(tracker.record(id, token: token, verdict: .fresh, samples: layoutA, now: 10.3))
    }

    /// Caught repainting (partial, blank or stale), the window may show an
    /// intermediate layout: two matching reads, like the SM-29 hold.
    func testAfterAnUnpaintedOrStaleReadTwoMatchingFreshReadsAreNeeded() {
        for first in [SnapshotFreshVerdict.partial, .blank, .stale] {
            var tracker = SnapshotFreshTracker()
            let token = tracker.start(id, now: 0)
            _ = tracker.capture(id, token: token)
            XCTAssertEqual(
                tracker.record(id, token: token, verdict: first, samples: layoutB, now: 0.2),
                .retry(after: SnapshotFreshTracker.retryInterval)
            )
            _ = tracker.capture(id, token: token)
            XCTAssertEqual(
                tracker.record(id, token: token, verdict: .fresh, samples: layoutA, now: 0.3),
                .retry(after: SnapshotFreshTracker.retryInterval), "\(first): one fresh read is not enough"
            )
            _ = tracker.capture(id, token: token)
            XCTAssertEqual(tracker.record(id, token: token, verdict: .fresh, samples: layoutB, now: 0.4), .retry(after: 0.04))
            _ = tracker.capture(id, token: token)
            XCTAssertEqual(tracker.record(id, token: token, verdict: .fresh, samples: layoutB, now: 0.5), .apply)
            XCTAssertEqual(tracker.outcome(id), SnapshotFreshOutcome(milliseconds: 500, attempts: 4, last: .fresh))
        }
    }

    func testAnUnknownReadRetriesWithoutAskingForConfirmation() {
        var tracker = SnapshotFreshTracker()
        let token = tracker.start(id, now: 0)
        _ = tracker.capture(id, token: token)
        XCTAssertEqual(tracker.record(id, token: token, verdict: .unknown, samples: [], now: 0.15), .retry(after: 0.04))
        _ = tracker.capture(id, token: token)
        XCTAssertEqual(tracker.record(id, token: token, verdict: .fresh, samples: layoutA, now: 0.25), .apply)
    }

    func testNoCaptureStartsPastTheLimit() {
        var tracker = SnapshotFreshTracker()
        XCTAssertEqual(SnapshotFreshTracker.limit, 0.6)
        let token = tracker.start(id, now: 0)
        _ = tracker.capture(id, token: token)
        XCTAssertEqual(tracker.record(id, token: token, verdict: .stale, samples: layoutA, now: 0.55), .retry(after: 0.04))
        _ = tracker.capture(id, token: token)
        XCTAssertEqual(tracker.record(id, token: token, verdict: .stale, samples: layoutA, now: 0.57), .stop)
        XCTAssertEqual(tracker.outcome(id), SnapshotFreshOutcome(milliseconds: nil, attempts: 2, last: .stale))
        XCTAssertFalse(tracker.capture(id, token: token))
    }

    /// A retarget to another size writes again: a new series; the old one's
    /// answers are dropped. Tokens never repeat, even across flights.
    func testANewSeriesSupersedesTheRunningOneAndTokensNeverRepeat() {
        var tracker = SnapshotFreshTracker()
        let first = tracker.start(id, now: 0)
        _ = tracker.capture(id, token: first)
        let second = tracker.start(id, now: 0.1)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(tracker.record(id, token: first, verdict: .fresh, samples: layoutA, now: 0.2))
        XCTAssertFalse(tracker.capture(id, token: first))
        XCTAssertEqual(tracker.outcome(id), SnapshotFreshOutcome(milliseconds: nil, attempts: 0, last: nil))
        tracker.removeAll()
        XCTAssertNil(tracker.outcome(id))
        XCTAssertNil(tracker.record(id, token: second, verdict: .fresh, samples: layoutA, now: 0.3))
        let third = tracker.start(id, now: 1)
        XCTAssertFalse([first, second].contains(third))
    }

    // MARK: log

    func testTheResizeLineSaysWhenTheFreshImageCameOrWhyNot() {
        XCTAssertEqual(
            snapshotResizeOutcomeLine(
                id, mode: .crossfade, fresh: SnapshotFreshOutcome(milliseconds: 212, attempts: 1, last: .fresh)
            ),
            "snapshot resize id=13261:4 mode=crossfade fresh=212 attempts=1"
        )
        XCTAssertEqual(
            snapshotResizeOutcomeLine(id, mode: .fill, fresh: SnapshotFreshOutcome(milliseconds: nil, attempts: 3, last: .stale)),
            "snapshot resize id=13261:4 mode=fill fresh=none attempts=3 last=stale"
        )
        XCTAssertEqual(
            snapshotResizeOutcomeLine(id, mode: .crop, fresh: SnapshotFreshOutcome(milliseconds: nil, attempts: 0, last: nil)),
            "snapshot resize id=13261:4 mode=crop fresh=none attempts=0"
        )
    }

    // MARK: soft hand-off

    /// Live: the real window differs for 1-3 frames after a resize (Electron
    /// re-lays out late); its layer fades out over it instead of a hard cut.
    /// A pure move (and a window without a layer) leaves at once.
    func testOnlyResizedWindowsWithALayerFadeOutAtTheHandOff() {
        let moved = WindowID(pid: 2, elementID: 1)
        let hole = WindowID(pid: 3, elementID: 1)
        XCTAssertEqual(snapshotHandoffFadeDuration, 0.12)
        XCTAssertEqual(snapshotHandoffFading(resized: [id, hole], layered: [id, moved]), [id])
        XCTAssertEqual(snapshotHandoffFading(resized: [], layered: [id, moved]), [])
    }
}
