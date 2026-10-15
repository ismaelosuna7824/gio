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
        XCTAssertEqual(evicted.map(\.id), [id(2)])
        XCTAssertNotNil(cache.entry(id(1)))
        XCTAssertNotNil(cache.entry(id(3)))
        XCTAssertLessThanOrEqual(cache.totalPixels, 130)
    }

    func testEnforceKeepsEverythingWhenUnderTheCap() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        XCTAssertEqual(cache.enforce(capPixels: 60).map(\.id), [])
    }

    /// SM-20: eight display-fulls, backdrops counted (see the cap doc).
    /// SM-22: never above 3 % of the physical memory at 4 bytes a pixel.
    func testCapIsEightDisplaysOfPixels() {
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: 1000, physicalMemory: 64 << 30), 8_000)
    }

    /// SM-22: the cap is the smaller of eight display-fulls and 3 % of the
    /// RAM (4 bytes a pixel). MacBook Air 13" (1470 x 956 pt @2x) and the
    /// user's display (1800 x 1169 pt @2x) on 8, 16 and 24 GB.
    func testCapIsTheSmallerOfEightDisplaysAndThreePercentOfTheRAM() {
        let air = 2940 * 1912
        let user = 3600 * 2338
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: air, physicalMemory: 8 * gb), 44_970_240, "Air 8 GB: display")
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: air, physicalMemory: 16 * gb), 44_970_240)
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: air, physicalMemory: 24 * gb), 44_970_240)
        XCTAssertEqual(
            snapshotCacheCapPixels(displayPixels: user, physicalMemory: 8 * gb), 64_424_509, "user's display 8 GB: RAM"
        )
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: user, physicalMemory: 16 * gb), 67_334_400)
        XCTAssertEqual(snapshotCacheCapPixels(displayPixels: user, physicalMemory: 24 * gb), 67_334_400)
        XCTAssertEqual(
            snapshotCacheCapLogLine(capPixels: 64_424_509, physicalMemory: 8 * gb),
            "snapshot cache cap pixels=64424509 ramMB=8192"
        )
    }

    /// SM-22: the shown strips at full resolution, every other window (a
    /// hidden workspace, seen only during a switch slide) at half the
    /// backing scale: a quarter of the pixels.
    func testShownStripWindowsAreCapturedAtFullAndHiddenOnesAtHalfResolution() {
        XCTAssertEqual(snapshotCaptureResolution(id(1), shown: [id(1)]), .full)
        XCTAssertEqual(snapshotCaptureResolution(id(2), shown: [id(1)]), .half)
        XCTAssertEqual(SnapshotResolution.full.scale, 1)
        XCTAssertEqual(SnapshotResolution.half.scale, 0.5)
        let full = snapshotPixelSize(points: frame.size, scale: 2 * SnapshotResolution.full.scale)
        let half = snapshotPixelSize(points: frame.size, scale: 2 * SnapshotResolution.half.scale)
        XCTAssertEqual(full.width * full.height, 4 * half.width * half.height, "a quarter of the pixels")
    }

    /// SM-22: a half-resolution image flies like any other (a switch never
    /// falls back because of it); once its window is in a shown strip the
    /// image is selected for a full-resolution capture, by the strip and by
    /// the refresh set alike. A hidden window keeps it.
    func testAHalfResolutionImageFliesAndIsRefreshedOnceItsWindowIsShown() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "half", frame: frame, pixels: 1, at: 100, resolution: .half)
        cache.store(id(2), image: "full", frame: frame, pixels: 1, at: 100)
        XCTAssertEqual(cache.entry(id(1))?.resolution, .half)
        XCTAssertEqual(cache.entry(id(2))?.resolution, .full, "full unless said otherwise")
        let use = cache.usableEntry(id(1), startFrame: frame, now: 101)
        XCTAssertEqual(use?.entry.image, "half")
        XCTAssertEqual(use?.otherSize, false)
        let strip = snapshotStripSelection(
            cache: cache, strip: [(id(1), frame), (id(2), frame)], dirty: [:], excluded: [], now: 101
        )
        XCTAssertEqual(strip.map(\.id), [id(1)])
        XCTAssertEqual(strip.map(\.cause), [.halfResolution])
        let wanted: [(id: WindowID, frame: CGRect)] = [(id(1), frame), (id(2), frame)]
        let shown = snapshotRefreshSelection(cache: cache, wanted: wanted, dirty: [:], now: 101, fullResolution: [id(1)])
        XCTAssertEqual(shown.map(\.cause), [.halfResolution])
        XCTAssertTrue(
            snapshotRefreshSelection(cache: cache, wanted: wanted, dirty: [:], now: 101).isEmpty,
            "hidden: the half-resolution image is what it wants"
        )
        XCTAssertEqual(snapshotRefreshReason(causes: [.halfResolution], backdrop: false), .settle)
    }

    /// SM-22: the cap drops full-resolution images of windows outside the
    /// shown strips (coverage brings them back at half) before any
    /// half-resolution image, and says which resolution each eviction was.
    func testEnforceEvictsFullImagesOfHiddenWindowsBeforeHalfOnes() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "strip", frame: frame, pixels: 40, at: 1)
        cache.store(id(2), image: "hidden-half", frame: frame, pixels: 10, at: 2, resolution: .half)
        cache.store(id(3), image: "hidden-full", frame: frame, pixels: 40, at: 3)
        cache.store(id(4), image: "hidden-half", frame: frame, pixels: 10, at: 4, resolution: .half)
        let evicted = cache.enforce(capPixels: 60, pinned: [id(1)]) { _ in self.frame }
        XCTAssertEqual(evicted, [SnapshotEviction(id: id(3), resolution: .full)], "the full image of a hidden window")
        XCTAssertEqual(cache.ids, [id(1), id(2), id(4)])
        let more = cache.enforce(capPixels: 50, pinned: [id(1)]) { _ in self.frame }
        XCTAssertEqual(more, [SnapshotEviction(id: id(2), resolution: .half)], "then half images, LRU")
        let strip = cache.enforce(capPixels: 10, pinned: [id(1)]) { _ in self.frame }
        XCTAssertEqual(strip.map(\.id), [id(4)], "the strip pin still wins over the cap")
        XCTAssertEqual(cache.ids, [id(1)])
    }

    /// SM-20: backdrops count against the cap but are never evicted.
    func testEnforceCountsTheBackdropsAgainstTheCap() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "b", frame: frame, pixels: 60, at: 2)
        cache.storeBackdrop(image: "d", displayFrame: frame, pixels: 50, at: 3)
        XCTAssertEqual(cache.enforce(capPixels: 130).map(\.id), [id(1)], "120 + 50 > 130: one image goes")
        XCTAssertEqual(cache.totalPixels + cache.backdropPixels, 110)
        XCTAssertNotNil(cache.backdrop(for: frame))
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

    // MARK: SM-09 freshness, backdrop, blank guard, refresh selection

    func testBackdropIsKeyedByDisplayFrameWithItsAge() {
        var cache = SnapshotCache<String>()
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        XCTAssertNil(cache.backdrop(for: left))
        cache.storeBackdrop(image: "L", displayFrame: left, pixels: 50, at: 10)
        cache.storeBackdrop(image: "R", displayFrame: right, pixels: 60, at: 12)
        XCTAssertEqual(cache.backdrop(for: left)?.image, "L")
        XCTAssertEqual(cache.backdrop(for: right)?.capturedAt, 12)
        XCTAssertEqual(cache.backdropPixels, 110)
        cache.storeBackdrop(image: "L2", displayFrame: left, pixels: 55, at: 20)
        XCTAssertEqual(cache.backdrop(for: left)?.image, "L2", "same display frame replaces")
        XCTAssertEqual(cache.backdropPixels, 115)
        XCTAssertEqual(cache.retainBackdrops(onlyFrames: [right]), [left])
        XCTAssertNil(cache.backdrop(for: left))
        cache.removeAll()
        XCTAssertNil(cache.backdrop(for: right))
    }

    func testBackdropIsUsableUntilItsMaxAge() {
        let entry = SnapshotBackdropEntry(image: "b", displayFrame: frame, capturedAt: 100, pixels: 1)
        XCTAssertTrue(snapshotBackdropUsable(entry, now: 399, maxAge: 300))
        XCTAssertFalse(snapshotBackdropUsable(entry, now: 401, maxAge: 300))
    }

    func testBlankCaptureIsAllTransparentOrOneOpaqueColour() {
        let clear: UInt32 = 0x0000_0000
        let white: UInt32 = 0xFFFF_FFFF
        let grey: UInt32 = 0xECEC_ECFF
        XCTAssertTrue(snapshotLooksBlank(samples: Array(repeating: clear, count: 25)), "nothing drawn")
        XCTAssertTrue(snapshotLooksBlank(samples: Array(repeating: white, count: 25)), "one flat colour")
        XCTAssertTrue(
            snapshotLooksBlank(samples: [clear, clear] + Array(repeating: white, count: 23)),
            "rounded corners around one flat colour"
        )
        XCTAssertFalse(snapshotLooksBlank(samples: [grey] + Array(repeating: white, count: 24)), "a title bar")
        XCTAssertFalse(snapshotLooksBlank(samples: []), "no samples: keep the image")
    }

    func testRefreshSelectionIsOnlyMissingResizedDirtyOrSoftStale() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "fresh", frame: frame, pixels: 1, at: 100)
        cache.store(id(2), image: "moved", frame: frame, pixels: 1, at: 100)
        cache.store(id(3), image: "resized", frame: frame, pixels: 1, at: 100)
        cache.store(id(4), image: "dirty", frame: frame, pixels: 1, at: 100)
        cache.store(id(5), image: "old", frame: frame, pixels: 1, at: 60)
        let wanted: [(id: WindowID, frame: CGRect)] = [
            (id(1), frame), (id(2), frame.offsetBy(dx: 900, dy: 0)),
            (id(3), CGRect(x: 0, y: 0, width: 700, height: 600)), (id(4), frame), (id(5), frame), (id(6), frame),
            (id(7), frame),
        ]
        let selected = snapshotRefreshSelection(
            cache: cache, wanted: wanted, dirty: [id(4): .typing, id(7): .new], now: 101, softAge: 30
        )
        XCTAssertEqual(selected.map(\.id), [id(3), id(4), id(5), id(6), id(7)], "wanted order; fresh and moved skipped")
        XCTAssertEqual(selected.map(\.cause), [.sizeChanged, .dirty(.typing), .stale, .missing, .dirty(.new)])
    }

    func testRefreshReasonIsTheMostSpecificCause() {
        XCTAssertEqual(snapshotRefreshReason(causes: [.stale, .missing], backdrop: false), .settle)
        XCTAssertEqual(snapshotRefreshReason(causes: [.stale, .dirty(.typing)], backdrop: false), .typing)
        XCTAssertEqual(snapshotRefreshReason(causes: [.dirty(.typing), .dirty(.focus)], backdrop: true), .focus)
        XCTAssertEqual(snapshotRefreshReason(causes: [.dirty(.focus), .sizeChanged], backdrop: false), .size)
        XCTAssertEqual(snapshotRefreshReason(causes: [.sizeChanged, .dirty(.new)], backdrop: false), .new)
        XCTAssertEqual(snapshotRefreshReason(causes: [], backdrop: true), .backdrop)
    }

    func testUnmanagedWindowFingerprintIgnoresManagedAndOwnWindows() {
        let managed = CGRect(x: 0, y: 0, width: 800, height: 600)
        let server = [
            ServerWindow(pid: 10, bounds: managed.offsetBy(dx: 1, dy: 0)),
            ServerWindow(pid: 10, bounds: CGRect(x: 900, y: 0, width: 300, height: 200)),
            ServerWindow(pid: 77, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            ServerWindow(pid: 20, bounds: CGRect(x: 100, y: 100, width: 50, height: 50)),
        ]
        let print = unmanagedWindowFingerprint(server: server, managed: [id(1): managed], ownPid: 77)
        XCTAssertEqual(
            print, [ServerWindowKey(pid: 10, x: 900, y: 0, width: 300, height: 200), ServerWindowKey(pid: 20, x: 100, y: 100, width: 50, height: 50)]
        )
        let moved = server.map { $0.pid == 20 ? ServerWindow(pid: 20, bounds: $0.bounds.offsetBy(dx: 10, dy: 0)) : $0 }
        XCTAssertNotEqual(unmanagedWindowFingerprint(server: moved, managed: [id(1): managed], ownPid: 77), print)
    }

    func testBackdropExcludesOnlyWindowsThatCanFly() {
        // Tiled windows fly as layers: cut out of the backdrop. Floating ones
        // never enter a flight, so the backdrop keeps them; minimized ones are off screen.
        XCTAssertTrue(backdropExcludesWindow(mode: .tiled, isMinimized: false))
        XCTAssertTrue(backdropExcludesWindow(mode: .fullscreen, isMinimized: false))
        XCTAssertFalse(backdropExcludesWindow(mode: .floating, isMinimized: false))
        XCTAssertFalse(backdropExcludesWindow(mode: .tiled, isMinimized: true))
    }

    func testTypingHopsReachTheSessionAtMostTwicePerSecond() {
        XCTAssertEqual(snapshotTypingHopInterval, 0.5)
        XCTAssertTrue(snapshotTypingHopDue(now: 10, lastHop: nil, interval: 0.5), "first key")
        XCTAssertFalse(snapshotTypingHopDue(now: 10.3, lastHop: 10, interval: 0.5))
        XCTAssertTrue(snapshotTypingHopDue(now: 10.5, lastHop: 10, interval: 0.5))
    }

    /// PF-V: a typing capture waits for a pause longer than the hop
    /// interval (steady typing never fires it) and for the floor since the
    /// window's last image.
    func testTypingCaptureWaitsForAPauseAndTheFloor() {
        XCTAssertGreaterThan(snapshotTypingQuiet, snapshotTypingHopInterval * 2)
        XCTAssertEqual(snapshotTypingCaptureDelay(capturedAt: nil, now: 10), snapshotTypingQuiet, "no image")
        XCTAssertEqual(snapshotTypingCaptureDelay(capturedAt: 0, now: 10), snapshotTypingQuiet, "old image")
        XCTAssertEqual(
            snapshotTypingCaptureDelay(capturedAt: 9, now: 10), snapshotTypingFloor - 1, accuracy: 1e-9,
            "an image 1 s old waits for the floor"
        )
    }

    // MARK: SM-11 two sizes per window, other-size fallback, off-screen, miss log

    private let maximized = CGRect(x: 0, y: 0, width: 1600, height: 600)

    func testKeepsTheLatestImageOfTwoSizesPerWindow() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "s1", frame: frame, pixels: 100, at: 1)
        cache.store(id(1), image: "m", frame: maximized, pixels: 200, at: 2)
        cache.store(id(1), image: "s2", frame: frame.offsetBy(dx: 300, dy: 0), pixels: 100, at: 3)
        XCTAssertEqual(cache.count, 1, "one window")
        XCTAssertEqual(cache.imageCount, 2, "latest per size")
        XCTAssertEqual(Set(cache.entries(of: id(1)).map(\.image)), ["s2", "m"])
        XCTAssertEqual(cache.entry(id(1))?.image, "s2", "the newest entry")
        XCTAssertEqual(cache.totalPixels, 300, "both sizes count against the cap")
    }

    func testAThirdSizeDropsTheLeastRecentlyUsedSizeOfTheWindow() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "s", frame: frame, pixels: 100, at: 1)
        cache.store(id(1), image: "m", frame: maximized, pixels: 200, at: 2)
        cache.touch(id(1), frame: frame, at: 5)
        cache.store(id(1), image: "l", frame: CGRect(x: 0, y: 0, width: 1200, height: 600), pixels: 150, at: 6)
        XCTAssertEqual(Set(cache.entries(of: id(1)).map(\.image)), ["s", "l"])
        XCTAssertEqual(cache.totalPixels, 250)
    }

    func testFlightUsesTheImageWhoseSizeMatchesTheStartFrame() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "s", frame: frame, pixels: 1, at: 1)
        cache.store(id(1), image: "m", frame: maximized, pixels: 1, at: 2)
        let small = cache.usableEntry(id(1), startFrame: frame.offsetBy(dx: 900, dy: 0), now: 10)
        XCTAssertEqual(small?.entry.image, "s")
        XCTAssertEqual(small?.otherSize, false)
        XCTAssertEqual(cache.usableEntry(id(1), startFrame: maximized, now: 10)?.entry.image, "m")
        XCTAssertEqual(cache.usableEntry(id(1), startFrame: nil, now: 10)?.entry.image, "m", "no frame: the newest")
    }

    /// SM-27: the other-size image is drawn at its own size (cropped or over
    /// the fill), never scaled; the soft age still bounds it.
    func testWithoutAMatchingSizeAFreshImageOfTheOtherSizeFlies() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "s", frame: frame, pixels: 1, at: 100)
        let use = cache.usableEntry(id(1), startFrame: maximized, now: 120)
        XCTAssertEqual(use?.entry.image, "s")
        XCTAssertEqual(use?.otherSize, true)
        XCTAssertEqual(use?.resize, .fill, "a column image on a maximized frame: unscaled over the fill")
        XCTAssertNil(cache.usableEntry(id(1), startFrame: maximized, now: 131), "older than the soft age: fall back")
        XCTAssertEqual(cache.usableEntry(id(1), startFrame: frame, now: 131)?.otherSize, false, "matching size: any age")
        XCTAssertNil(cache.usableEntry(id(2), startFrame: frame, now: 101))
    }

    // MARK: SM-27 resize without stretching

    /// Alt+F with both sizes cached: the layer starts on the column image and
    /// swaps to the maximized one; back again the other way round.
    func testAResizeFlightGetsTheImageOfItsTargetSizeToSwapTo() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "column", frame: frame, pixels: 1, at: 1)
        cache.store(id(1), image: "maximized", frame: maximized, pixels: 1, at: 2)
        let grow = cache.usableEntry(id(1), startFrame: frame, targetFrame: maximized, now: 10)
        XCTAssertEqual(grow?.entry.image, "column")
        XCTAssertEqual(grow?.target?.image, "maximized")
        XCTAssertEqual(grow?.resize, .swap)
        let shrink = cache.usableEntry(id(1), startFrame: maximized, targetFrame: frame.offsetBy(dx: 40, dy: 0), now: 10)
        XCTAssertEqual(shrink?.entry.image, "maximized")
        XCTAssertEqual(shrink?.target?.image, "column")
        XCTAssertEqual(shrink?.resize, .swap)
    }

    /// The first maximize of a window (never captured at that size): no
    /// second image, the column image stays unscaled over its edge fill;
    /// shrinking without the smaller image crops the larger one.
    func testWithoutTheTargetSizeTheStartImageFillsOrCrops() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "column", frame: frame, pixels: 1, at: 1)
        let grow = cache.usableEntry(id(1), startFrame: frame, targetFrame: maximized, now: 10)
        XCTAssertEqual(grow?.entry.image, "column")
        XCTAssertNil(grow?.target)
        XCTAssertEqual(grow?.resize, .fill)
        cache.store(id(2), image: "maximized", frame: maximized, pixels: 1, at: 1)
        let shrink = cache.usableEntry(id(2), startFrame: maximized, targetFrame: frame, now: 10)
        XCTAssertNil(shrink?.target)
        XCTAssertEqual(shrink?.resize, .crop)
    }

    func testAPureMoveNeedsNoResizeAndItsTargetIsTheSameImage() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "column", frame: frame, pixels: 1, at: 1)
        cache.store(id(1), image: "maximized", frame: maximized, pixels: 1, at: 2)
        let move = cache.usableEntry(id(1), startFrame: frame, targetFrame: frame.offsetBy(dx: 900, dy: 0), now: 10)
        XCTAssertEqual(move?.target?.image, "column")
        XCTAssertNil(move?.resize)
        XCTAssertNil(cache.usableEntry(id(1), startFrame: frame, now: 10)?.resize, "no target frame: a move")
    }

    func testAnEntryKeepsTheFillSampledFromItsEdge() {
        var cache = SnapshotCache<String>()
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        cache.store(id(1), image: "column", frame: frame, pixels: 1, at: 1, fill: white)
        cache.store(id(2), image: "clear", frame: frame, pixels: 1, at: 1)
        XCTAssertEqual(cache.entry(id(1))?.fill, white)
        XCTAssertEqual(cache.entry(id(1))?.face, SnapshotFace(image: "column", size: frame.size, fill: white))
        XCTAssertNil(cache.entry(id(2))?.fill, "no fill unless sampled")
    }

    /// Live 2026-10-09 21:38: Tern's column-size image was pruned 30 s into
    /// a maximize (`pruned images=1 reason=size`); Alt+F back to a column then
    /// flew the maximized image squeezed into the column (`snapshot scaled`,
    /// SM-27 never scales any more) for the 7 s of the next burst, until a
    /// settle captured the new size.
    func testBothSizesOfAWindowSurviveSettlesSoAToggleBackFliesItsOwnImage() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "column", frame: frame, pixels: 1, at: 0)
        cache.store(id(1), image: "maximized", frame: maximized, pixels: 1, at: 10)
        let pruned = cache.prune(now: 100, currentFrame: { _ in self.maximized }, displayFrames: [])
        XCTAssertTrue(pruned.images.isEmpty, "the size it is not at now stays")
        let back = cache.usableEntry(id(1), startFrame: frame, now: 100)
        XCTAssertEqual(back?.entry.image, "column")
        XCTAssertEqual(back?.otherSize, false)
    }

    /// Live 2026-10-09 21:27: after a 3-4 min pause the images of the strip's
    /// parked windows had expired (`pruned ... reason=age`); the next Alt+L
    /// burst showed them through holes and fell back to the AX motion four
    /// times. A parked window cannot be captured again, and an old picture of
    /// the right size for 350 ms beats a hole or an AX slide.
    func testAnImageOfTheCurrentSizeFliesWhateverItsAge() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "old", frame: frame, pixels: 1, at: 0)
        let use = cache.usableEntry(id(1), startFrame: frame.offsetBy(dx: 1800, dy: 0), now: 3600)
        XCTAssertEqual(use?.entry.image, "old")
        XCTAssertEqual(use?.otherSize, false)
        XCTAssertEqual(cache.usableEntry(id(1), startFrame: nil, now: 3600)?.entry.image, "old", "no frame: the newest")
        let pruned = cache.prune(now: 3600, currentFrame: { _ in self.frame }, displayFrames: [])
        XCTAssertTrue(pruned.images.isEmpty, "a settle keeps it")
        XCTAssertEqual(cache.entry(id(1))?.image, "old")
    }

    func testEnforceEvictsSecondSizesBeforeAnyWindowLosesItsOnlyImage() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "b", frame: frame, pixels: 60, at: 2)
        cache.store(id(2), image: "b-max", frame: maximized, pixels: 60, at: 3)
        let evicted = cache.enforce(capPixels: 130)
        XCTAssertEqual(evicted.map(\.id), [id(2)])
        XCTAssertEqual(cache.entries(of: id(2)).map(\.image), ["b-max"], "the window keeps its newest image")
        XCTAssertNotNil(cache.entry(id(1)))
    }

    func testEnforceEvictsTheSizeTheWindowIsNotAtFirst() {
        // SM-13: Alt+F then Alt+F back: the normal-size image is the older
        // capture but the window is at that size again.
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "a", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "b", frame: frame, pixels: 60, at: 2)
        cache.store(id(2), image: "b-max", frame: maximized, pixels: 60, at: 3)
        let evicted = cache.enforce(capPixels: 130, protected: []) { _ in self.frame }
        XCTAssertEqual(evicted.map(\.id), [id(2)])
        XCTAssertEqual(cache.entries(of: id(2)).map(\.image), ["b"], "the current size stays")
    }

    func testEnforceNeverEvictsTheOnScreenImagesBeforeHiddenCoverage() {
        // SM-13: the visible windows were captured earlier; a coverage stage
        // just stored hidden-workspace windows (newer lastUsed).
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "visible", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "adjacent", frame: frame, pixels: 60, at: 2)
        cache.store(id(3), image: "hidden", frame: frame, pixels: 60, at: 10)
        cache.store(id(4), image: "hidden", frame: frame, pixels: 60, at: 10)
        let evicted = cache.enforce(capPixels: 130, protected: [id(1), id(2)]) { _ in self.frame }
        XCTAssertEqual(Set(evicted.map(\.id)), [id(3), id(4)])
        XCTAssertNotNil(cache.entry(id(1)))
        XCTAssertNotNil(cache.entry(id(2)))
    }

    func testProtectedImagesGoOnlyWhenNothingElseIsLeft() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "visible", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "visible", frame: frame, pixels: 60, at: 2)
        cache.store(id(3), image: "hidden", frame: frame, pixels: 60, at: 10)
        XCTAssertEqual(cache.enforce(capPixels: 60, protected: [id(1), id(2)]) { _ in nil }.map(\.id), [id(3), id(1)])
    }

    func testRefreshSelectionAcceptsAFreshImageOfEitherSize() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "s", frame: frame, pixels: 1, at: 100)
        cache.store(id(1), image: "m", frame: maximized, pixels: 1, at: 101)
        let selected = snapshotRefreshSelection(
            cache: cache, wanted: [(id(1), frame)], dirty: [:], now: 102, softAge: 30
        )
        XCTAssertTrue(selected.isEmpty, "Alt+F back: the small image is still there")
    }

    func testAFrameUnderEightPointsOnScreenIsOffScreen() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let sliver = CGRect(x: 1799, y: 0, width: 800, height: 1169)
        XCTAssertTrue(snapshotFrameIsOffScreen(sliver, displays: [display]), "a parking frame")
        XCTAssertTrue(snapshotFrameIsOffScreen(sliver.offsetBy(dx: -6.5, dy: 0), displays: [display]))
        XCTAssertFalse(snapshotFrameIsOffScreen(sliver.offsetBy(dx: -7, dy: 0), displays: [display]), "8 pt shows")
        XCTAssertTrue(snapshotFrameIsOffScreen(frame.offsetBy(dx: 5000, dy: 0), displays: [display]))
        XCTAssertFalse(snapshotFrameIsOffScreen(frame, displays: [display]))
        XCTAssertTrue(snapshotFrameIsOffScreen(frame, displays: []))
    }

    // MARK: SM-20 pruning and memory pressure

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let goneDisplay = CGRect(x: 1800, y: 0, width: 1440, height: 900)

    /// A settle drops exactly what no flight can use: an image of a window
    /// without a frame past the max age, and backdrops of gone displays. A
    /// placed window keeps every image (SM-24: the current size at any age;
    /// SM-25: the other size, exact when the window toggles back).
    func testPruneDropsOnlyImagesNoFlightCanUse() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "old", frame: frame, pixels: 10, at: 0)
        cache.store(id(2), image: "fresh", frame: frame, pixels: 10, at: 100)
        cache.store(id(2), image: "max-old", frame: maximized, pixels: 10, at: 160)
        cache.store(id(3), image: "small", frame: frame, pixels: 10, at: 30)
        cache.store(id(3), image: "max-new", frame: maximized, pixels: 10, at: 175)
        cache.store(id(4), image: "unknown-old", frame: frame, pixels: 10, at: 10)
        cache.store(id(5), image: "unknown-new", frame: maximized, pixels: 10, at: 100)
        cache.storeBackdrop(image: "here", displayFrame: display, pixels: 10, at: 0)
        cache.storeBackdrop(image: "gone", displayFrame: goneDisplay, pixels: 10, at: 0)
        let current: (WindowID) -> CGRect? = { [4, 5].contains($0.elementID) ? nil : self.frame }
        let pruned = cache.prune(now: 200, currentFrame: current, displayFrames: [display])
        XCTAssertEqual(pruned.images, [.age: 1, .display: 1])
        XCTAssertEqual(pruned.emptied, [id(4)])
        XCTAssertEqual(pruned.logLines, [
            "snapshot cache pruned images=1 reason=age",
            "snapshot cache pruned images=1 reason=display",
        ])
        XCTAssertEqual(cache.entry(id(1))?.image, "old", "the current size, past the max age: still flies")
        XCTAssertEqual(Set(cache.entries(of: id(2)).map(\.image)), ["fresh", "max-old"])
        XCTAssertEqual(Set(cache.entries(of: id(3)).map(\.image)), ["small", "max-new"])
        XCTAssertNil(cache.entry(id(4)))
        XCTAssertEqual(cache.entry(id(5))?.image, "unknown-new", "no current frame: the max age alone")
        XCTAssertEqual(cache.backdrop(for: display)?.image, "here", "a backdrop of a shown display always flies")
        XCTAssertNil(cache.backdrop(for: goneDisplay))
        for id in cache.ids {
            for entry in cache.entries(of: id) {
                XCTAssertNotNil(cache.usableEntry(id, startFrame: entry.frame, now: 200), "every kept image can fly")
            }
        }
        XCTAssertEqual(cache.prune(now: 200, currentFrame: current, displayFrames: [display]).logLines, [])
    }

    // MARK: SM-21 the shown strip survives pressure and the cap

    /// id 1 on the shown strip (both sizes), id 2 on an adjacent workspace
    /// (both sizes), id 3 hidden (a current-size image and a secondary
    /// one), id 4 hidden with an unusable image (past the max age).
    private func pressureFixture() -> SnapshotCache<String> {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "strip", frame: frame, pixels: 10, at: 101)
        cache.store(id(1), image: "strip-max", frame: maximized, pixels: 10, at: 102)
        cache.store(id(2), image: "adjacent", frame: frame, pixels: 10, at: 103)
        cache.store(id(2), image: "adjacent-max", frame: maximized, pixels: 10, at: 104)
        cache.store(id(3), image: "hidden", frame: frame, pixels: 10, at: 150)
        cache.store(id(3), image: "hidden-max", frame: maximized, pixels: 10, at: 150)
        cache.store(id(4), image: "hidden-old", frame: frame, pixels: 10, at: 0)
        cache.storeBackdrop(image: "here", displayFrame: display, pixels: 10, at: 0)
        cache.storeBackdrop(image: "gone", displayFrame: goneDisplay, pixels: 10, at: 0)
        return cache
    }

    /// SM-21: a warning is not a purge. Only unusable or secondary images
    /// of windows away from the shown and adjacent workspaces go (and the
    /// backdrops of gone displays); every image of those workspaces stays.
    func testWarningPressureDropsOnlyUnusableOrSecondaryImagesAwayFromTheShownWorkspaces() {
        var cache = pressureFixture()
        let freed = cache.relieve(
            .warning, shown: [id(1)], adjacent: [id(2)], currentFrame: { _ in self.frame },
            displayFrames: [display], now: 200
        )
        XCTAssertEqual(freed, 3, "hidden-max, hidden-old and the gone display's backdrop")
        XCTAssertEqual(cache.ids, [id(1), id(2), id(3)])
        XCTAssertEqual(Set(cache.entries(of: id(1)).map(\.image)), ["strip", "strip-max"], "the strip keeps everything")
        XCTAssertEqual(Set(cache.entries(of: id(2)).map(\.image)), ["adjacent", "adjacent-max"])
        XCTAssertEqual(cache.entries(of: id(3)).map(\.image), ["hidden"], "a usable current-size image stays")
        XCTAssertNotNil(cache.backdrop(for: display))
        XCTAssertNil(cache.backdrop(for: goneDisplay))
    }

    /// SM-21: critical keeps every window of the shown strips at its
    /// current size and the shown backdrops; everything else goes.
    func testCriticalPressureKeepsTheShownStripAtCurrentSizeAndShownBackdrops() {
        var cache = pressureFixture()
        let freed = cache.relieve(
            .critical, shown: [id(1)], adjacent: [id(2)], currentFrame: { _ in self.frame },
            displayFrames: [display], now: 200
        )
        XCTAssertEqual(freed, 7)
        XCTAssertEqual(cache.ids, [id(1)])
        XCTAssertEqual(cache.entries(of: id(1)).map(\.image), ["strip"])
        XCTAssertEqual(cache.backdrop(for: display)?.image, "here")
        XCTAssertEqual(cache.backdropPixels, 10)
        var unknown = pressureFixture()
        unknown.relieve(
            .critical, shown: [id(1)], adjacent: [], currentFrame: { _ in nil }, displayFrames: [display], now: 200
        )
        XCTAssertEqual(unknown.imageCount, 0, "no current frame: no current-size image to keep")
    }

    /// SM-21: every strip window without a usable current-size image is
    /// selected (missing, only another size, past the max age), whether or
    /// not it was tried before (the selection has no notion of tried); a
    /// known blank/unmatchable parked window is not; a dirty one reports
    /// its mark. Strip order.
    func testStripSelectionPicksEveryStripWindowWithoutAUsableCurrentSizeImage() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "fresh", frame: frame, pixels: 1, at: 100)
        cache.store(id(3), image: "other-size", frame: maximized, pixels: 1, at: 190)
        cache.store(id(4), image: "expired", frame: frame, pixels: 1, at: 10)
        cache.store(id(6), image: "fresh-dirty", frame: frame, pixels: 1, at: 190)
        let strip = (1...6).map { (id: id(UInt64($0)), frame: frame) }
        let selected = snapshotStripSelection(
            cache: cache, strip: strip, dirty: [id(6): .typing], excluded: [id(5)], now: 200
        )
        XCTAssertEqual(selected.map(\.id), [id(2), id(3), id(4), id(6)])
        XCTAssertEqual(selected.map(\.cause), [.missing, .sizeChanged, .stale, .dirty(.typing)])
        XCTAssertTrue(
            snapshotStripSelection(cache: cache, strip: [(id(1), frame)], dirty: [:], excluded: [], now: 200).isEmpty,
            "a fresh current-size image: nothing to do (the soft age is the refresh set's rule)"
        )
    }

    /// SM-21: the cap yields to the shown strip: its windows' current-size
    /// images are never evicted, even over the cap; the strip's other sizes
    /// and then other windows go first (SM-25).
    func testEnforceNeverEvictsTheStripsCurrentSizeImages() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "strip", frame: frame, pixels: 60, at: 1)
        cache.store(id(2), image: "strip", frame: frame, pixels: 60, at: 2)
        cache.store(id(2), image: "strip-max", frame: maximized, pixels: 60, at: 3)
        cache.store(id(3), image: "hidden", frame: frame, pixels: 60, at: 10)
        let evicted = cache.enforce(capPixels: 60, protected: [], pinned: [id(1), id(2)]) { _ in self.frame }
        XCTAssertEqual(evicted.map(\.id), [id(2), id(3)], "the strip's other size, then the hidden window")
        XCTAssertEqual(cache.entries(of: id(1)).map(\.image), ["strip"])
        XCTAssertEqual(cache.entries(of: id(2)).map(\.image), ["strip"])
        XCTAssertEqual(cache.totalPixels, 120, "over the cap: the strip wins")
        XCTAssertEqual(snapshotStripCapLogLine(images: 2), "snapshot cache cap exceeded by strip images=2")
    }

    /// Live 2026-10-09 21:45-21:46: with both sizes kept (SM-25), Alt+F on
    /// the strip filled the cap with second sizes and the cap evicted the only
    /// images of hidden-workspace windows (`evicted=1..2`); the next Alt+1/2/3
    /// switches showed one window through a hole each time. A second size is
    /// only needed for an Alt+F back; a hidden window's only image for every
    /// switch.
    func testAnyWindowsOtherSizeGoesBeforeAHiddenWindowsOnlyImage() {
        var cache = SnapshotCache<String>()
        cache.store(id(1), image: "visible", frame: frame, pixels: 60, at: 1)
        cache.store(id(1), image: "visible-max", frame: maximized, pixels: 60, at: 2)
        cache.store(id(2), image: "hidden", frame: frame, pixels: 60, at: 3)
        let evicted = cache.enforce(capPixels: 120, protected: [id(1)]) { _ in self.frame }
        XCTAssertEqual(evicted.map(\.id), [id(1)])
        XCTAssertEqual(cache.entries(of: id(1)).map(\.image), ["visible"])
        XCTAssertEqual(cache.entry(id(2))?.image, "hidden", "the hidden window keeps its only image")
    }

    func testPressureLineCarriesTheLevelAndTheFreedImages() {
        XCTAssertEqual(snapshotPressureLogLine(level: .warning, freed: 3), "snapshot cache pressure level=warning freed=3")
        XCTAssertEqual(snapshotPressureLogLine(level: .critical, freed: 0), "snapshot cache pressure level=critical freed=0")
    }

    func testMissLineNamesTheWindowReasonAndAppOnly() {
        XCTAssertEqual(
            snapshotMissLogLine(id: WindowID(pid: 5618, elementID: 3), reason: .overBudget, app: "WhatsApp"),
            "snapshot miss id=5618:3 reason=over-budget app=WhatsApp"
        )
    }

    func testMissIsLoggedOncePerWindowAndReasonPerMinute() {
        var throttle = SnapshotMissLogThrottle()
        XCTAssertTrue(throttle.shouldLog(id(1), reason: .unmatched, now: 100))
        XCTAssertFalse(throttle.shouldLog(id(1), reason: .unmatched, now: 159))
        XCTAssertTrue(throttle.shouldLog(id(1), reason: .blank, now: 159), "another reason")
        XCTAssertTrue(throttle.shouldLog(id(2), reason: .unmatched, now: 159), "another window")
        XCTAssertTrue(throttle.shouldLog(id(1), reason: .unmatched, now: 160), "a minute later")
    }

    // MARK: SM-31 undrawn windows

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let tile = CGRect(x: 0, y: 100, width: 800, height: 900)

    /// A capture found no WindowServer window (`unmatched`) and the
    /// on-screen list has nothing of the app over its frame: macOS does
    /// not draw it.
    func testAnUnmatchedWindowWithNothingOfItsAppOnScreenIsUndrawn() {
        let elsewhere = ServerWindow(pid: 10, bounds: CGRect(x: 1000, y: 100, width: 700, height: 900))
        XCTAssertEqual(
            snapshotUndrawnWindows(
                misses: [id(1): .unmatched], frames: [id(1): tile],
                server: [elsewhere, ServerWindow(pid: 11, bounds: tile)], viewports: [screen]
            ),
            [id(1)]
        )
    }

    /// FI-08's unknown windows keep their image: another miss reason, a
    /// window less than half on a display (peek and edge columns, parking
    /// slivers), an app drawing something over its frame, an ambiguous
    /// same-size match, a window drawn elsewhere, an unavailable on-screen
    /// list, or no frame.
    func testWindowsTheRenderCheckCannotJudgeAreNeverUndrawn() {
        let peek = CGRect(x: 1500, y: 100, width: 800, height: 900)
        let other = ServerWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        let cases: [(String, [WindowID: SnapshotMiss], [WindowID: CGRect], [ServerWindow])] = [
            ("ambiguous miss", [id(1): .ambiguous], [id(1): tile], [other]),
            ("blank miss", [id(1): .blank], [id(1): tile], [other]),
            ("over budget", [id(1): .overBudget], [id(1): tile], [other]),
            ("peek column", [id(1): .unmatched], [id(1): peek], [other]),
            ("overlaps", [id(1): .unmatched], [id(1): tile],
             [ServerWindow(pid: 10, bounds: CGRect(x: 0, y: 100, width: 400, height: 900))]),
            ("ambiguous same size", [id(1): .unmatched], [id(1): tile], [
                ServerWindow(pid: 10, bounds: tile.offsetBy(dx: 900, dy: 0)),
                ServerWindow(pid: 10, bounds: tile.offsetBy(dx: 950, dy: 50)),
            ]),
            ("drawn elsewhere", [id(1): .unmatched], [id(1): tile],
             [ServerWindow(pid: 10, bounds: tile.offsetBy(dx: 900, dy: 0))]),
            ("no on-screen list", [id(1): .unmatched], [id(1): tile], []),
            ("no frame", [id(1): .unmatched], [:], [other]),
        ]
        for (name, misses, frames, server) in cases {
            XCTAssertEqual(
                snapshotUndrawnWindows(misses: misses, frames: frames, server: server, viewports: [screen]), [], name
            )
        }
    }

    func testTheEvictLineNamesTheWindowAndTheReasonOnly() {
        XCTAssertEqual(
            snapshotEvictLine(id: WindowID(pid: 5618, elementID: 3), reason: .vanished),
            "snapshot evict id=5618:3 reason=vanished"
        )
        XCTAssertEqual(
            snapshotEvictLine(id: WindowID(pid: 7, elementID: 1), reason: .undrawn), "snapshot evict id=7:1 reason=undrawn"
        )
    }
}
