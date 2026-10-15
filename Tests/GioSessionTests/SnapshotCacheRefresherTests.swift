import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// SM-04/SM-09: the snapshot cache refresher on a virtual clock: settle
/// refresh (selective), dirty signals, backdrop, pruning, no timers at rest.
final class SnapshotCacheRefresherTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var rendererAvailable = true
        var ghostWanted = false
        var motion = false
        var flight = false
        var shuttingDown = false
        var serverWindows: [ServerWindow] = []
        var captures: [SnapshotCaptureRequest] = []
        var completions: [@Sendable (SnapshotCaptureOutcome) -> Void] = []
        var prefetches: [Set<WindowID>] = []
        var prefetchDone: [@Sendable () -> Void] = []
        var logs: [(LogLevel, String)] = []
        /// Capture scale and image size: small values put the cache under its cap.
        var captureScale: CGFloat = 1
        var imageSize = (width: 4, height: 2)
        /// SM-20: images sized like the window (points x this) instead of `imageSize`.
        var imageScale: CGFloat?
    }

    private let a = CGRect(x: 0, y: 100, width: 800, height: 900)
    private let b = CGRect(x: 820, y: 100, width: 800, height: 900)
    private let screen = SessionFixture.screen
    private var world: World!
    private var fixture: SessionFixture!
    private var scheduler: ManualScheduler!
    private var cache: SnapshotCacheRefresher!
    private var idA: WindowID!
    private var idB: WindowID!

    override func setUp() {
        world = World()
        fixture = SessionFixture(frames: [a, b], focus: 0)
        scheduler = ManualScheduler()
        idA = SessionFixture.id(0, pid: 1)
        idB = SessionFixture.id(1, pid: 2)
        makeCache()
    }

    /// SM-22: 64 GB by default, so the display-based cap governs.
    private func makeCache(physicalMemory: UInt64 = 64 << 30) {
        let world = world!
        let fixture = fixture!
        let scheduler = scheduler!
        cache = SnapshotCacheRefresher(
            context: .init(
                session: { fixture.session },
                displays: { fixture.displays.allDisplays() },
                physicalFrame: { fixture.physicalFrames[$0] },
                isShuttingDown: { world.shuttingDown },
                isFlightActive: { world.flight },
                isMotionActive: { world.motion },
                rendererAvailable: { world.rendererAvailable },
                ghostCacheWanted: { world.ghostWanted },
                captureScreens: {
                    ([SnapshotDisplay(id: 1, frame: SessionFixture.screen, scale: world.captureScale)], SessionFixture.screen.height)
                },
                capture: { request, done in
                    world.captures.append(request)
                    world.completions.append(done)
                },
                prefetch: { managed, done in
                    world.prefetches.append(managed)
                    world.prefetchDone.append(done)
                },
                serverWindows: { world.serverWindows },
                ownPid: 999,
                log: { world.logs.append(($0, $1)) },
                appName: { "app\($0)" },
                physicalMemory: physicalMemory,
                now: { scheduler.now }
            ),
            scheduler: scheduler
        )
    }

    /// SM-22: `half` images have half the width and height, like the capturer's.
    private func image(for frame: CGRect? = nil, half: Bool = false) -> CGImage {
        let factor = half ? SnapshotResolution.half.scale : 1
        let size = frame.flatMap { frame in
            world.imageScale.map { snapshotPixelSize(points: frame.size, scale: $0 * factor) }
        } ?? (half ? (width: max(1, world.imageSize.width / 2), height: max(1, world.imageSize.height / 2)) : world.imageSize)
        let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Completes the last capture with `images` and, by default, a backdrop.
    private func complete(
        _ images: [WindowID: CGRect], backdrop: Bool = true, misses: [WindowID: SnapshotMiss] = [:]
    ) {
        let done = world.completions.removeLast()
        let half = lastRequest?.halfResolution ?? []
        done(SnapshotCaptureOutcome(
            images: Dictionary(uniqueKeysWithValues: images.map { id, frame in
                (id, CapturedImage(image: image(for: frame, half: half.contains(id)), frame: frame))
            }),
            backdrops: backdrop ? [CapturedBackdropImage(image: image(for: screen), displayFrame: screen)] : [],
            misses: misses
        ))
        scheduler.runPending()
    }

    /// Completes the last capture with an image for every requested window.
    private func completeAll(backdrop: Bool = true) {
        complete(lastRequest?.windows ?? [:], backdrop: backdrop)
    }

    /// Runs one settle refresh and completes its capture with `images`.
    private func refresh(
        _ images: [WindowID: CGRect], backdrop: Bool = true, misses: [WindowID: SnapshotMiss] = [:]
    ) {
        cache.schedule()
        scheduler.advance(by: 0.3)
        complete(images, backdrop: backdrop, misses: misses)
    }

    /// A parking frame at the right edge (1 pt sliver), as Gio writes it.
    private let parked = CGRect(x: 1799, y: 100, width: 800, height: 900)
    private var nextColumn: UInt64 = 100

    /// Registers `count` windows (one column each, unfocused) on workspace
    /// `index` of the display's stack, parked like every hidden window.
    private func addWindows(_ count: Int, workspace index: Int) throws -> [WindowID] {
        var ids: [WindowID] = []
        for _ in 0..<count {
            nextColumn += 1
            let id = WindowID(pid: pid_t(nextColumn), elementID: nextColumn)
            try fixture.session.registry.register(ManagedWindow(
                id: id, pid: id.pid, application: "App", title: "secret", frame: parked, mode: .tiled
            ))
            var workspace = try XCTUnwrap(fixture.session.manager.workspace(index))
            workspace.columns.append(Column(id: ColumnID(nextColumn), width: 0, windows: [id]))
            fixture.session.manager.update(workspace)
            fixture.physicalFrames[id] = parked
            ids.append(id)
        }
        return ids
    }

    private var lastRequest: SnapshotCaptureRequest? { world.captures.last }

    // MARK: Settle refresh (selective)

    func testFirstSettleCapturesEverythingAndTheBackdrop() throws {
        cache.schedule()
        scheduler.advance(by: 0.3)
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(Set(request.windows.keys), [idA, idB])
        XCTAssertEqual(request.backdropDisplayIDs, [1], "missing backdrop captured with the first settle")
        XCTAssertEqual(Set(request.backdropExclusions.keys), [idA, idB], "every managed window is left out")
        XCTAssertEqual(request.reason, .settle)
        XCTAssertFalse(request.includeBackdrop)
    }

    func testSettleAfterAScrollCapturesNothingWhenAllFresh() {
        refresh([idA: a, idB: b])
        fixture.physicalFrames[idA] = a.offsetBy(dx: -300, dy: 0)
        fixture.physicalFrames[idB] = b.offsetBy(dx: -300, dy: 0)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1, "moved windows keep their images")
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot refresh skipped wanted=2 fresh" })
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testSettleCapturesOnlyTheResizedWindow() {
        refresh([idA: a, idB: b])
        fixture.physicalFrames[idB] = CGRect(x: 820, y: 100, width: 600, height: 900)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idB])
        XCTAssertEqual(lastRequest?.reason, .size)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [], "backdrop still fresh")
    }

    func testSettleRecapturesSoftStaleImages() {
        refresh([idA: a, idB: b])
        scheduler.advance(by: 31)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA, idB])
        XCTAssertEqual(lastRequest?.reason, .settle)
    }

    func testRefreshIsDebouncedToTheLatestRequest() {
        cache.schedule()
        scheduler.advance(by: 0.1)
        cache.schedule()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.captures.count, 1)
    }

    func testRefreshWhileBusyRunsOnceMoreAfterTheCapture() {
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1, "busy: remembered, not started")

        world.completions.removeFirst()(SnapshotCaptureOutcome(images: [idA: CapturedImage(image: image(), frame: a)]))
        scheduler.runPending()
        scheduler.advance(by: 0.05)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(Set(world.captures[1].windows.keys), [idB], "only what the first run did not deliver")
    }

    func testRefreshWaitsForMotionAndFlight() {
        world.motion = true
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertTrue(world.captures.isEmpty)
    }

    func testFinishPrunesDeadAndMinimizedWindows() throws {
        refresh([idA: a, idB: b, WindowID(pid: 99, elementID: 9): a])
        XCTAssertEqual(cache.cache.ids, [idA, idB])
        var record = try XCTUnwrap(fixture.session.registry.find(idB))
        record.isMinimized = true
        try fixture.session.registry.update(record)
        scheduler.advance(by: 31)
        refresh([idA: a])
        XCTAssertEqual(cache.cache.ids, [idA])
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("snapshot cache entries=1") })
    }

    func testUnusableRendererDropsTheCacheAndSchedulesNothing() {
        refresh([idA: a, idB: b])
        world.rendererAvailable = false
        XCTAssertFalse(cache.rendererUsable())
        XCTAssertEqual(cache.cache.count, 0)
        XCTAssertNil(cache.backdrop(for: screen))
        cache.schedule()
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: Backdrop (SM-09)

    func testBackdropIsServedByDisplayFrameRegardlessOfAge() {
        refresh([idA: a, idB: b])
        XCTAssertNotNil(cache.backdrop(for: screen))
        XCTAssertNil(cache.backdrop(for: screen.offsetBy(dx: 1, dy: 0)))
        XCTAssertEqual(cache.backdropAge(for: screen), 0)
        scheduler.advance(by: 301)
        XCTAssertNotNil(cache.backdrop(for: screen), "stale beats a fallback; the next settle re-captures")
        XCTAssertEqual(cache.backdropAge(for: screen), 301)
    }

    func testSettleRecapturesAnExpiredBackdrop() {
        refresh([idA: a, idB: b])
        scheduler.advance(by: 301)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [1])
    }

    func testBackdropIsRecapturedWhenTheUnmanagedWindowsChange() {
        world.serverWindows = [ServerWindow(pid: 1, bounds: a), ServerWindow(pid: 2, bounds: b)]
        refresh([idA: a, idB: b])
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1, "same unmanaged set: nothing")

        world.serverWindows.append(ServerWindow(pid: 50, bounds: CGRect(x: 100, y: 100, width: 300, height: 200)))
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(lastRequest?.windows.count, 0)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [1])
        XCTAssertEqual(lastRequest?.reason, .backdrop)
        complete([:])

        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 2, "captured: clean again")
    }

    func testMarkedDirtyBackdropIsCapturedAndStaysDirtyUntilDelivered() {
        refresh([idA: a, idB: b])
        cache.markBackdropDirty()
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [1])
        complete([:], backdrop: false)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 3, "not delivered: tried again")
        complete([:])
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 3)
    }

    func testGhostOnlyCacheNeverCapturesABackdrop() {
        world.rendererAvailable = false
        world.ghostWanted = true
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [])
    }

    // MARK: Dirty signals (SM-09)

    /// PF-V: the typing hop resets the wait at most every 0.5 s, so with the
    /// old 0.6 s debounce steady typing still captured every second or two.
    /// Now a typing capture waits for a real pause (`snapshotTypingQuiet`)
    /// and never comes sooner than `snapshotTypingFloor` after the window's
    /// last image: one capture per pause, at most one per floor.
    func testTypingCapturesTheFocusedWindowOnlyAfterAPauseAndAtMostOncePerFloor() {
        refresh([idA: a, idB: b])
        for _ in 0..<20 {
            cache.noteTyping()
            scheduler.advance(by: 0.5)
        }
        XCTAssertEqual(world.captures.count, 1, "steady typing: no capture")
        scheduler.advance(by: snapshotTypingQuiet - 0.5)
        XCTAssertEqual(world.captures.count, 2, "the pause")
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA])
        XCTAssertEqual(lastRequest?.reason, .typing)
        XCTAssertEqual(lastRequest?.backdropDisplayIDs, [])
        complete([idA: a])

        cache.noteTyping()
        scheduler.advance(by: snapshotTypingQuiet)
        XCTAssertEqual(world.captures.count, 2, "a pause right after a capture waits for the floor")
        scheduler.advance(by: snapshotTypingFloor - snapshotTypingQuiet)
        XCTAssertEqual(world.captures.count, 3)
        complete([idA: a])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// SM-11: Alt+H/L only moves the focus; the content of neither window
    /// changed, so nothing is captured.
    func testFocusChangeAloneCapturesNothing() {
        refresh([idA: a, idB: b])
        cache.noteFocus(idA)
        scheduler.advance(by: 1)
        cache.noteFocus(idB)
        scheduler.advance(by: 1)
        cache.noteFocus(idA)
        scheduler.advance(by: 2.9)
        XCTAssertEqual(world.captures.count, 1, "focus changes: no capture")
        XCTAssertTrue(cache.dirty.isEmpty)
    }

    /// SM-11: a window focused for 3 s is likely used (scrolled, clicked):
    /// it becomes dirty once and is captured once.
    func testWindowFocusedForThreeSecondsIsCapturedOnce() {
        refresh([idA: a, idB: b])
        cache.noteFocus(idB)
        scheduler.advance(by: 2.9)
        XCTAssertNil(cache.dirty[idB])
        scheduler.advance(by: 0.1)
        XCTAssertEqual(cache.dirty[idB], .focus)
        scheduler.advance(by: 0.6)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idB])
        XCTAssertEqual(lastRequest?.reason, .focus)
        complete([idB: b])
        scheduler.advance(by: 600)
        XCTAssertEqual(world.captures.count, 2, "once per focus")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testNewWindowIsCapturedOnceAfterRegistration() throws {
        refresh([idA: a, idB: b])
        let fresh = WindowID(pid: 3, elementID: 3)
        let frame = CGRect(x: 1640, y: 100, width: 800, height: 900)
        try fixture.session.registry.register(ManagedWindow(
            id: fresh, pid: 3, application: "App2", title: "secret", frame: frame, mode: .tiled
        ))
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(3), width: 0, windows: [fresh]))
        fixture.session.manager.update(workspace)
        cache.noteRegistered(fresh)
        // The placing reflow settles before the dirty debounce fires.
        fixture.physicalFrames[fresh] = frame
        cache.schedule()
        scheduler.advance(by: 0.6)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [fresh])
        XCTAssertEqual(lastRequest?.reason, .new)
        complete([fresh: frame])
        scheduler.advance(by: 1)
        XCTAssertEqual(world.captures.count, 2, "once")
    }

    func testDirtySignalsAreIgnoredForTheGhostOnlyCache() {
        world.rendererAvailable = false
        world.ghostWanted = true
        cache.noteTyping()
        cache.noteFocus(idB)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDirtyRunDeferredByMotionIsPickedUpByTheSettle() {
        refresh([idA: a, idB: b])
        cache.noteTyping()
        world.motion = true
        scheduler.advance(by: snapshotTypingFloor)
        XCTAssertEqual(world.captures.count, 1, "motion: not now")
        world.motion = false
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA], "the dirty mark survived")
    }

    func testEvictedWindowLosesItsDirtyMark() {
        refresh([idA: a, idB: b])
        cache.noteTyping()
        cache.evict([idA])
        scheduler.advance(by: snapshotTypingFloor)
        XCTAssertEqual(world.captures.count, 1, "a purged window is not captured")
    }

    // MARK: Coverage, parked misses, attributed misses (SM-11)

    /// Every window of every workspace gets an image after the first
    /// settle, at most 12 per run, re-scheduled while some are missing;
    /// never during motion, and no timer once everything is covered.
    func testWarmUpCoversEveryWorkspaceInStagesOfTwelve() throws {
        let second = try addWindows(6, workspace: 2)
        let third = try addWindows(8, workspace: 3)
        cache.schedule()
        scheduler.advance(by: 0.3)
        let first = try XCTUnwrap(lastRequest)
        XCTAssertEqual(first.windows.count, 12, "one budgeted stage")
        XCTAssertTrue(Set(first.windows.keys).isSuperset(of: [idA, idB]), "the visible windows first")
        completeAll()
        XCTAssertEqual(scheduler.pendingCount, 1, "the next stage is scheduled")

        world.motion = true
        scheduler.advance(by: 1)
        XCTAssertEqual(world.captures.count, 1, "never during motion")
        world.motion = false
        cache.schedule()
        scheduler.advance(by: 0.3)
        let rest = try XCTUnwrap(lastRequest)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(
            Set(first.windows.keys).union(rest.windows.keys), Set([idA, idB] + second + third),
            "every workspace covered"
        )
        XCTAssertEqual(rest.windows.count, 4)
        completeAll()
        scheduler.advance(by: 600)
        XCTAssertEqual(world.captures.count, 2, "covered: nothing more")
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
    }

    /// SM-13: under the cap the coverage images go first, never the
    /// visible ones; SM-22: once the cap cannot hold even half-resolution
    /// coverage images it stops (logged once) and resumes when a window
    /// leaves the cache.
    func testCoverageNeverEvictsTheVisibleImagesAndStopsAtTheCap() throws {
        // 1800 x 1169 at 0.01: 18 x 11 pixels per display, cap 1584 (SM-20:
        // eight displays, the 200-pixel backdrop counted): 400 for the
        // strip, room for nineteen 50-pixel half-resolution images.
        world.captureScale = 0.01
        world.imageSize = (20, 10)
        refresh([idA: a, idB: b])
        scheduler.advance(by: 1)
        let hidden = try addWindows(30, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.windows.count, 12, "one coverage stage")
        completeAll(backdrop: false)
        XCTAssertEqual(scheduler.pendingCount, 1, "half resolution fits: the next stage")
        scheduler.advance(by: SnapshotCacheRefresher.stageDelay)
        XCTAssertEqual(lastRequest?.windows.count, 12)
        completeAll(backdrop: false)
        XCTAssertNotNil(cache.flightImage(idA, startFrame: a, at: scheduler.now), "the visible images stay")
        XCTAssertNotNil(cache.flightImage(idB, startFrame: b, at: scheduler.now))
        XCTAssertLessThanOrEqual(cache.cache.totalPixels + cache.cache.backdropPixels, 1584)
        XCTAssertEqual(scheduler.pendingCount, 0, "the cap cannot hold more coverage: no next stage")
        let stopped = world.logs.filter { $0.1.hasPrefix("snapshot coverage stopped") }
        XCTAssertEqual(stopped.count, 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 3, "no coverage while stopped")
        XCTAssertEqual(world.logs.filter { $0.1.hasPrefix("snapshot coverage stopped") }.count, 1, "logged once")

        cache.evict([hidden[0]])
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 4, "a window left the cache: coverage resumes")
    }

    /// A window that misses while parked is not retried on every settle and
    /// leaves the dirty set; it is captured when it is next visible.
    func testParkedMissIsNotRetriedUntilTheWindowIsVisible() throws {
        refresh([idA: a, idB: b])
        let hidden = try XCTUnwrap(addWindows(1, workspace: 1).first)
        cache.noteRegistered(hidden)
        scheduler.advance(by: 0.6)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [hidden])
        complete([:], misses: [hidden: .unmatched])
        XCTAssertNil(cache.dirty[hidden], "the dirty set drains")
        XCTAssertTrue(world.logs.contains { $0.1.hasSuffix("dirty=0") })

        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 2, "parked: not retried")
        XCTAssertEqual(scheduler.pendingCount, 0)

        fixture.physicalFrames[hidden] = CGRect(x: 900, y: 100, width: 800, height: 900)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [hidden], "visible again: captured")
    }

    /// SM-17: the startup coverage asks for every parked window once; one
    /// that captures blank (never painted while parked) keeps no image and
    /// is not asked again until it shows (the overlay hole covers it).
    func testStartupCoverageAsksEveryParkedWindowOnceAndDropsABlankOne() throws {
        let parkedIDs = try addWindows(3, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), Set([idA, idB] + parkedIDs))
        complete([idA: a, idB: b, parkedIDs[0]: parked, parkedIDs[1]: parked], misses: [parkedIDs[2]: .blank])
        XCTAssertNil(cache.flightImage(parkedIDs[2], startFrame: parked, at: scheduler.now), "blank: no image")
        XCTAssertNotNil(cache.flightImage(parkedIDs[0], startFrame: parked, at: scheduler.now))
        XCTAssertEqual(scheduler.pendingCount, 0, "no stage for a blank parked window")
        for _ in 0..<3 {
            cache.schedule()
            scheduler.advance(by: 0.3)
        }
        XCTAssertEqual(world.captures.count, 1, "never retried while parked")
        fixture.physicalFrames[parkedIDs[2]] = CGRect(x: 900, y: 100, width: 800, height: 900)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [parkedIDs[2]], "visible again: captured")
    }

    /// A window on a hidden workspace that coverage could not capture is
    /// tried again only when it moves to another workspace (or registers).
    func testCoverageRetriesAMissOnlyAfterTheWindowMovesWorkspace() throws {
        let second = try addWindows(1, workspace: 2)
        let hidden = try XCTUnwrap(addWindows(1, workspace: 3).first)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertTrue(lastRequest?.windows.keys.contains(hidden) ?? false)
        complete([idA: a, idB: b, second[0]: parked], misses: [hidden: .overBudget])
        XCTAssertEqual(scheduler.pendingCount, 0, "no further stage for a tried window")
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1, "tried once: not every settle")

        var from = try XCTUnwrap(fixture.session.manager.workspace(3))
        from.columns.removeAll { $0.windows.contains(hidden) }
        var to = try XCTUnwrap(fixture.session.manager.workspace(2))
        to.columns.append(Column(id: ColumnID(999), width: 0, windows: [hidden]))
        fixture.session.manager.update(to)
        fixture.session.manager.update(from)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [hidden], "moved: tried again")
    }

    // MARK: Half-resolution hidden workspaces, RAM cap (SM-22)

    /// Puts workspace `index` on the display, its windows at `frames` (the
    /// rest parked).
    private func show(workspace index: Int, frames: [WindowID: CGRect]) throws {
        XCTAssertTrue(fixture.session.manager.switchTo(index))
        XCTAssertTrue(fixture.displays.assign(SessionFixture.display, workspace: fixture.session.manager.currentID))
        for id in fixture.physicalFrames.keys {
            fixture.physicalFrames[id] = frames[id] ?? parked
        }
    }

    /// The shown strip is captured at full resolution, the windows of
    /// hidden workspaces at half; a half image flies like any other.
    func testHiddenWorkspaceWindowsAreRequestedAtHalfResolutionAndTheShownStripAtFull() throws {
        let hidden = try addWindows(3, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(Set(request.windows.keys), Set([idA!, idB!] + hidden))
        XCTAssertEqual(request.halfResolution, Set(hidden))
        completeAll()
        for id in hidden {
            XCTAssertEqual(cache.cache.entry(id)?.resolution, .half)
            XCTAssertNotNil(cache.flightImage(id, startFrame: parked, at: scheduler.now), "a switch flies it")
        }
        XCTAssertEqual(cache.cache.entry(idA)?.resolution, .full)
        XCTAssertEqual(cache.cache.entry(idB)?.resolution, .full)
    }

    /// A switch slides the half images in; the settle after it captures
    /// the now-shown strip at full resolution, once. The workspace left
    /// keeps its full images (nothing captured for it).
    func testASwitchedToWorkspaceIsCapturedAtFullResolutionAfterTheSettle() throws {
        let hidden = try addWindows(2, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        try show(workspace: 2, frames: [hidden[0]: a, hidden[1]: b])
        XCTAssertNotNil(cache.flightImage(hidden[0], startFrame: a, at: scheduler.now), "the slide never holes")
        cache.schedule()
        scheduler.advance(by: 0.3)
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(Set(request.windows.keys), Set(hidden))
        XCTAssertEqual(request.halfResolution, [], "shown now: full resolution")
        completeAll()
        XCTAssertEqual(hidden.map { cache.cache.entry($0)?.resolution }, [.full, .full])
        XCTAssertEqual(cache.cache.entry(idA)?.resolution, .full, "the workspace left keeps its image")
        let captures = world.captures.count
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, captures, "fresh at full resolution: nothing more")
    }

    /// Coverage resumes under the cap: the full images a workspace kept
    /// from when it was shown go before any half image, and coverage
    /// brings the window back at half resolution without stopping.
    func testAnEvictedFullImageOfAHiddenWindowComesBackAtHalfWithoutStoppingCoverage() throws {
        // 18 x 11 pixels per display: cap 1584; full images 200, half 50.
        world.captureScale = 0.01
        world.imageSize = (20, 10)
        let second = try addWindows(4, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        try show(workspace: 2, frames: [second[0]: a, second[1]: b])
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll(backdrop: false)
        XCTAssertEqual(cache.cache.totalPixels + cache.cache.backdropPixels, 1400, "six full images and the backdrop")
        try show(workspace: 1, frames: [idA: a, idB: b])
        let third = try addWindows(4, workspace: 3)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.halfResolution, Set(third))
        completeAll(backdrop: false)
        let gone = second.filter { cache.cache.entry($0) == nil }
        XCTAssertEqual(gone.count, 1, "1600 > 1584: one full image of a hidden window goes")
        XCTAssertEqual(third.map { cache.cache.entry($0)?.resolution }, [.half, .half, .half, .half])
        XCTAssertEqual(scheduler.pendingCount, 1, "coverage goes on")
        scheduler.advance(by: SnapshotCacheRefresher.stageDelay)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), Set(gone))
        XCTAssertEqual(lastRequest?.halfResolution, Set(gone))
        completeAll(backdrop: false)
        XCTAssertEqual(cache.cache.entry(gone[0])?.resolution, .half)
        XCTAssertLessThanOrEqual(cache.cache.totalPixels + cache.cache.backdropPixels, 1584)
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot coverage stopped") })
        XCTAssertEqual(scheduler.pendingCount, 0, "covered")
    }

    /// The cap is computed from the display and the RAM and logged once.
    func testTheCapIsLoggedOnceAtStart() {
        makeCache(physicalMemory: 8 << 30)
        world.captureScale = 0.01
        refresh([idA: a, idB: b])
        scheduler.advance(by: 31)
        refresh([idA: a, idB: b])
        let lines = world.logs.filter { $0.1.hasPrefix("snapshot cache cap pixels=") }
        XCTAssertEqual(lines.map(\.1), ["snapshot cache cap pixels=1584 ramMB=8192"])
        XCTAssertEqual(lines.map(\.0), [.debug])
    }

    /// A small machine: 3 % of the RAM is below eight display-fulls, so the
    /// RAM cap governs; the shown strip still wins over it.
    func testATightRAMCapDropsHiddenImagesButNeverTheStrip() throws {
        makeCache(physicalMemory: 40_000)
        world.captureScale = 0.01
        world.imageSize = (20, 10)
        _ = try addWindows(2, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        XCTAssertEqual(cache.cache.ids, [idA, idB], "the strip stays, the hidden images go")
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot cache cap pixels=300 ramMB=0" })
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot cache cap exceeded by strip images=2" })
    }

    // MARK: Pruning, memory pressure, cap (SM-20)

    /// A settle drops the images no flight can use (logged by reason) and
    /// keeps the images of placed windows: old ones of the current size
    /// (SM-24) and the other size (SM-25); a stale hidden-workspace window is
    /// not captured again on the next settles (no capture loop), the visible
    /// ones are.
    func testSettlePrunesWhatNoFlightCanUseAndNeverRecapturesItInALoop() throws {
        let adjacent = try XCTUnwrap(addWindows(1, workspace: 2).first)
        let hidden = try XCTUnwrap(addWindows(1, workspace: 3).first)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA, idB, adjacent, hidden])
        completeAll()

        let narrow = CGRect(x: 820, y: 100, width: 600, height: 900)
        scheduler.advance(by: 10)
        fixture.physicalFrames[idB] = narrow
        refresh([idB: narrow])
        XCTAssertEqual(cache.cache.entries(of: idB).count, 2, "both sizes of b")
        scheduler.advance(by: 40)
        refresh([idA: a, idB: narrow])
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot cache pruned") }, "nothing to prune")
        XCTAssertEqual(cache.cache.entries(of: idB).map(\.frame.width).sorted(), [narrow.width, b.width].sorted(), "both sizes of b stay")
        XCTAssertNotNil(cache.cache.entry(hidden), "50 s: still usable")

        scheduler.advance(by: 140)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertFalse(world.logs.contains { $0.1.hasSuffix("reason=age") }, "190 s, current size: kept")
        XCTAssertNotNil(cache.flightImage(hidden, startFrame: fixture.physicalFrames[hidden], at: scheduler.now))
        XCTAssertNotNil(cache.flightImage(adjacent, startFrame: fixture.physicalFrames[adjacent], at: scheduler.now))
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA, idB], "only the refresh set is captured again")
        completeAll()
        let captures = world.captures.count
        for _ in 0..<3 {
            cache.schedule()
            scheduler.advance(by: 0.3)
        }
        XCTAssertEqual(world.captures.count, captures, "stale hidden windows: no capture loop")
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
    }

    /// A stale hidden window (SM-24: kept, it still flies) is captured
    /// again once its workspace becomes adjacent to the shown one.
    func testAStaleHiddenWindowIsCapturedAgainWhenItsWorkspaceBecomesAdjacent() throws {
        let second = try XCTUnwrap(addWindows(1, workspace: 2).first)
        let hidden = try XCTUnwrap(addWindows(1, workspace: 3).first)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        scheduler.advance(by: 190)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        XCTAssertNotNil(cache.cache.entry(hidden), "past the max age: kept")

        XCTAssertTrue(fixture.session.manager.switchTo(2))
        XCTAssertTrue(fixture.displays.assign(SessionFixture.display, workspace: fixture.session.manager.currentID))
        fixture.physicalFrames[idA] = parked
        fixture.physicalFrames[idB] = parked
        fixture.physicalFrames[second] = a
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [second, hidden], "shown, and its workspace became adjacent")
        completeAll()
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 3, "captured once")
    }

    func testSettleDropsTheBackdropOfAGoneDisplay() {
        let gone = CGRect(x: 1800, y: 0, width: 1440, height: 900)
        cache.schedule()
        scheduler.advance(by: 0.3)
        world.completions.removeLast()(SnapshotCaptureOutcome(
            images: [idA: CapturedImage(image: image(), frame: a), idB: CapturedImage(image: image(), frame: b)],
            backdrops: [
                CapturedBackdropImage(image: image(), displayFrame: screen),
                CapturedBackdropImage(image: image(), displayFrame: gone),
            ]
        ))
        scheduler.runPending()
        XCTAssertNotNil(cache.backdrop(for: gone))
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertNil(cache.backdrop(for: gone))
        XCTAssertNotNil(cache.backdrop(for: screen))
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot cache pruned images=1 reason=display") })
    }

    // MARK: Shown strip coverage, pressure recovery, cap (SM-21)

    /// SM-21: a warning drops no image of the shown or adjacent
    /// workspaces (both sizes of a strip window stay); only a hidden
    /// window's secondary image goes, and it is not captured again.
    func testMemoryPressureWarningDropsNoImageOfTheShownOrAdjacentWorkspaces() throws {
        let strip = try addWindows(2, workspace: 1)
        let second = try XCTUnwrap(addWindows(1, workspace: 2).first)
        let hidden = try XCTUnwrap(addWindows(1, workspace: 3).first)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        let narrow = CGRect(x: 820, y: 100, width: 600, height: 900)
        fixture.physicalFrames[idB] = narrow
        refresh([idB: narrow])
        fixture.physicalFrames[hidden] = CGRect(x: 1799, y: 100, width: 600, height: 900)
        cache.noteMemoryPressure(.warning)
        XCTAssertEqual(cache.cache.ids, Set([idA, idB, second] + strip), "the strip and the adjacent workspace stay")
        XCTAssertEqual(cache.cache.entries(of: idB).count, 2, "both sizes of a strip window stay")
        XCTAssertNil(cache.cache.entry(hidden), "only the hidden window's other size went")
        XCTAssertNotNil(cache.backdrop(for: screen))
        XCTAssertTrue(world.logs.contains { $0 == (.info, "snapshot cache pressure level=warning freed=1") })
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 2, "the strip is intact; the hidden window stays tried")
    }

    /// SM-21: critical keeps every window of the shown strip (beyond the
    /// visible and neighbour columns too) at its current size.
    func testMemoryPressureCriticalKeepsTheShownStripAtCurrentSizeAndTheBackdrop() throws {
        let strip = try addWindows(2, workspace: 1)
        let second = try XCTUnwrap(addWindows(1, workspace: 2).first)
        cache.schedule()
        scheduler.advance(by: 0.3)
        completeAll()
        let narrow = CGRect(x: 820, y: 100, width: 600, height: 900)
        fixture.physicalFrames[idB] = narrow
        refresh([idB: narrow])
        cache.noteMemoryPressure([.warning, .critical])
        XCTAssertEqual(cache.cache.ids, Set([idA, idB] + strip))
        XCTAssertEqual(cache.cache.entries(of: idB).map(\.frame), [narrow])
        XCTAssertNil(cache.cache.entry(second), "the adjacent workspace goes")
        XCTAssertNotNil(cache.backdrop(for: screen))
        XCTAssertTrue(world.logs.contains { $0 == (.info, "snapshot cache pressure level=critical freed=2") })
    }

    /// SM-21: strip windows a critical relief left without an image (they
    /// had only another size) are captured by the next settle, staged by
    /// twelve, although every one of them was tried; never during a
    /// flight; no timer once the strip is covered.
    func testAfterACriticalReliefTheNextSettleRecapturesTheStripInStages() throws {
        let strip = try addWindows(18, workspace: 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.windows.count, 12)
        completeAll()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.windows.count, 8, "the warm-up covers the strip in two stages")
        completeAll()
        XCTAssertEqual(cache.cache.count, 20)
        XCTAssertEqual(scheduler.pendingCount, 0)

        let resized = CGRect(x: 1799, y: 100, width: 700, height: 900)
        for id in strip {
            fixture.physicalFrames[id] = resized
        }
        cache.noteMemoryPressure(.critical)
        XCTAssertEqual(cache.cache.ids, [idA, idB], "the resized strip windows had only another size")
        cache.schedule()
        scheduler.advance(by: 0.3)
        let first = try XCTUnwrap(lastRequest)
        XCTAssertEqual(first.windows.count, 12, "one budgeted stage of the strip")
        XCTAssertTrue(Set(first.windows.keys).isSubset(of: strip))
        completeAll()
        XCTAssertEqual(scheduler.pendingCount, 1, "the next stage is scheduled")
        world.flight = true
        scheduler.advance(by: 1)
        XCTAssertEqual(world.captures.count, 3, "never during a flight")
        world.flight = false
        cache.schedule()
        scheduler.advance(by: 0.3)
        let rest = try XCTUnwrap(lastRequest)
        XCTAssertEqual(Set(first.windows.keys).union(rest.windows.keys), Set(strip), "the whole strip again")
        XCTAssertEqual(rest.windows.count, 6)
        completeAll()
        scheduler.advance(by: 600)
        XCTAssertEqual(world.captures.count, 4)
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
    }

    /// SM-21 (live 21:41): strip windows beyond the visible and neighbour
    /// columns whose image went stale (past the max age; SM-24: kept, it
    /// still flies) are captured again by the next settle although they were
    /// tried; no loop.
    func testStaleStripWindowsBeyondTheNeighbourColumnAreCapturedAgainAlthoughTried() throws {
        let strip = try addWindows(3, workspace: 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), Set([idA, idB] + strip))
        completeAll()
        XCTAssertFalse(Set(cache.refreshSet().map(\.id)).contains(strip[2]), "beyond the neighbour column")
        scheduler.advance(by: 190)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertFalse(world.logs.contains { $0.1.hasSuffix("reason=age") }, "stale strip images are kept")
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), Set([idA, idB] + strip), "the whole strip")
        completeAll()
        let captures = world.captures.count
        for _ in 0..<3 {
            cache.schedule()
            scheduler.advance(by: 0.3)
        }
        XCTAssertEqual(world.captures.count, captures, "covered: no capture loop")
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
    }

    /// SM-21: a strip window that keeps missing while visible is asked
    /// once per settle, never in a stage loop.
    func testAStripWindowThatKeepsMissingIsNotRetriedInAStageLoop() throws {
        let strip = try addWindows(14, workspace: 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        let first = try XCTUnwrap(lastRequest)
        complete(first.windows.filter { $0.key != idA }, misses: [idA: .failed])
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: 0.3)
        let rest = try XCTUnwrap(lastRequest)
        XCTAssertFalse(rest.windows.keys.contains(idA), "asked once in this pass")
        XCTAssertEqual(Set(first.windows.keys).union(rest.windows.keys), Set([idA, idB] + strip))
        complete(rest.windows)
        scheduler.advance(by: 20)
        XCTAssertEqual(world.captures.count, 2)
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idA], "the next settle asks again")
    }

    func testANormalMemoryEventWithoutPressureChangesNothing() {
        refresh([idA: a, idB: b])
        cache.noteMemoryPressure(.normal)
        XCTAssertEqual(cache.cache.imageCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot cache pressure") })
    }

    /// SM-21 recovery: pressure back to normal re-captures what the shown
    /// strip lacks (one run, then rest).
    func testPressureBackToNormalRecapturesWhatTheStripLacks() throws {
        refresh([idA: a, idB: b])
        let narrow = CGRect(x: 820, y: 100, width: 600, height: 900)
        fixture.physicalFrames[idB] = narrow
        cache.noteMemoryPressure(.critical)
        XCTAssertNil(cache.cache.entry(idB), "only another size: dropped")
        cache.noteMemoryPressure(.normal)
        XCTAssertTrue(world.logs.contains { $0 == (.info, "snapshot cache pressure level=normal") })
        XCTAssertEqual(scheduler.pendingCount, 1, "one recovery run")
        scheduler.advance(by: 0.3)
        XCTAssertEqual(Set(lastRequest?.windows.keys ?? [:].keys), [idB])
        completeAll()
        scheduler.advance(by: 600)
        XCTAssertEqual(scheduler.pendingCount, 0, "no timers at rest")
        cache.noteMemoryPressure(.normal)
        XCTAssertEqual(scheduler.pendingCount, 0, "recovered once")
    }

    /// SM-21: the cap never evicts the shown strip; when the strip alone
    /// exceeds it the cap yields (hidden images go) and says so once.
    func testTheCapYieldsToTheStripAndLogsItOnce() throws {
        // 18 x 11 pixels per display: cap 1584; ten 200-pixel strip images
        // plus the 200-pixel backdrop exceed it (the two adjacent-workspace
        // windows go).
        world.captureScale = 0.01
        world.imageSize = (20, 10)
        let strip = try addWindows(8, workspace: 1)
        _ = try addWindows(2, workspace: 2)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(lastRequest?.windows.count, 12)
        completeAll()
        XCTAssertEqual(cache.cache.ids, Set([idA, idB] + strip), "every strip image stays")
        XCTAssertGreaterThan(cache.cache.totalPixels + cache.cache.backdropPixels, 1584)
        let line = (LogLevel.debug, "snapshot cache cap exceeded by strip images=10")
        XCTAssertEqual(world.logs.filter { $0 == line }.count, 1)
        cache.noteTyping()
        scheduler.advance(by: snapshotTypingFloor)
        complete([idA: a])
        XCTAssertEqual(cache.cache.ids, Set([idA, idB] + strip))
        XCTAssertEqual(world.logs.filter { $0 == line }.count, 1, "logged once")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// SM-20 cap: a heavy but typical three-workspace setup on the user's
    /// display (1800 x 1169 pt @2x, scaled down 20x): the shown workspace
    /// is the middle one, every window display-size (maximized), so its
    /// visible column, both neighbour columns and the focused windows of
    /// both adjacent workspaces, plus the backdrop, must fit under the cap
    /// with room for coverage, and nothing of that set is evicted.
    func testTheVisibleAndAdjacentSetOfAThreeWorkspaceSetupFitsUnderTheCap() throws {
        world.captureScale = 0.1
        world.imageScale = 0.1
        let full = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        var workspace = try XCTUnwrap(fixture.session.manager.workspace(1))
        workspace.focusedColumn = 0
        workspace.focusedWindow = idA
        fixture.session.manager.update(workspace)
        let middle = try addWindows(3, workspace: 2)
        let below = try addWindows(2, workspace: 3)
        for (index, ids) in [(2, middle), (3, below)] {
            var workspace = try XCTUnwrap(fixture.session.manager.workspace(index))
            workspace.focusedColumn = index == 2 ? 1 : 0
            workspace.focusedWindow = index == 2 ? ids[1] : ids[0]
            fixture.session.manager.update(workspace)
        }
        XCTAssertTrue(fixture.session.manager.switchTo(2))
        XCTAssertTrue(fixture.displays.assign(SessionFixture.display, workspace: fixture.session.manager.currentID))
        for id in [idA!, idB!] + middle + below {
            fixture.physicalFrames[id] = CGRect(origin: parked.origin, size: full.size)
        }
        fixture.physicalFrames[middle[1]] = full
        let wanted = Set(cache.refreshSet().map(\.id))
        XCTAssertEqual(wanted, Set(middle + [idA!, below[0]]), "visible, both neighbours, adjacent focused")
        cache.schedule()
        scheduler.advance(by: 0.3)
        complete(Dictionary(uniqueKeysWithValues: wanted.map { ($0, fixture.physicalFrames[$0]!) }))
        let displayPixels = 180 * 116
        let used = cache.cache.totalPixels + cache.cache.backdropPixels
        XCTAssertLessThanOrEqual(used, 6 * displayPixels, "five window images and the backdrop")
        XCTAssertLessThanOrEqual(used + 2 * displayPixels, snapshotCacheCapPixels(displayPixels: displayPixels, physicalMemory: 64 << 30))
        XCTAssertTrue(world.logs.contains { $0.1.contains("evicted=0") })
        XCTAssertEqual(cache.cache.ids, wanted)
    }

    func testMissesAreLoggedWithReasonAndAppOncePerMinute() {
        refresh([idA: a], misses: [idB: .ambiguous])
        let line = "snapshot miss id=2:2 reason=ambiguous app=app2"
        XCTAssertTrue(world.logs.contains { $0 == (.debug, line) })
        refresh([:], misses: [idB: .ambiguous])
        XCTAssertEqual(world.captures.count, 2, "visible: retried at the next settle")
        XCTAssertEqual(world.logs.filter { $0.1 == line }.count, 1, "once per minute")
        scheduler.advance(by: 60)
        refresh([:], misses: [idB: .ambiguous])
        XCTAssertEqual(world.logs.filter { $0.1 == line }.count, 2)
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret") }, "never a title")
    }

    // MARK: SM-31 vanished and undrawn windows

    /// idA is on screen; pid 2 draws nothing anywhere.
    private var onlyADrawn: [ServerWindow] { [ServerWindow(pid: 1, bounds: a)] }

    private func evictions(_ reason: String) -> [String] {
        world.logs.filter { $0.0 == .debug && $0.1.hasPrefix("snapshot evict") && $0.1.hasSuffix(reason) }.map(\.1)
    }

    /// A shown-strip window a capture found no WindowServer window for,
    /// with nothing of its app on screen over its frame, loses its image at
    /// once (it would fly, then vanish at the hand-off, on every motion)
    /// and stays undrawn until a later capture matches it again.
    func testAnUnmatchedStripWindowLosesItsImageUntilACaptureMatchesItAgain() {
        refresh([idA: a, idB: b])
        world.serverWindows = onlyADrawn
        scheduler.advance(by: 31)
        refresh([idA: a], misses: [idB: .unmatched])

        XCTAssertNotNil(cache.flightImage(idA, startFrame: a, at: scheduler.now), "a drawn window keeps its image")
        XCTAssertNil(cache.flightImage(idB, startFrame: b, at: scheduler.now), "the old image never flies again")
        XCTAssertEqual(cache.undrawnWindows, [idB])
        XCTAssertEqual(evictions("reason=undrawn"), ["snapshot evict id=2:2 reason=undrawn"])

        refresh([:], misses: [idB: .unmatched])
        XCTAssertEqual(Set(world.captures.last?.windows.keys ?? [:].keys), [idB], "asked again at the next settle")
        XCTAssertEqual(evictions("reason=undrawn").count, 1, "one line per eviction, not per miss")

        world.serverWindows = [ServerWindow(pid: 1, bounds: a), ServerWindow(pid: 2, bounds: b)]
        refresh([idB: b])
        XCTAssertTrue(cache.undrawnWindows.isEmpty, "matched again")
        XCTAssertNotNil(cache.flightImage(idB, startFrame: b, at: scheduler.now))
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret") }, "never a title")
    }

    /// FI-08's unknown windows keep their image: the app draws something
    /// over the frame, the match was ambiguous, or no on-screen list.
    func testWindowsTheRenderCheckCannotJudgeKeepTheirImageAfterAMiss() {
        refresh([idA: a, idB: b])
        world.serverWindows = [ServerWindow(pid: 1, bounds: a), ServerWindow(pid: 2, bounds: b.insetBy(dx: 100, dy: 100))]
        scheduler.advance(by: 31)
        refresh([:], misses: [idB: .unmatched])
        world.serverWindows = onlyADrawn
        refresh([:], misses: [idB: .ambiguous])
        world.serverWindows = []
        refresh([:], misses: [idB: .unmatched])

        XCTAssertEqual(world.captures.count, 4, "idB was asked for each time")
        XCTAssertNotNil(cache.flightImage(idB, startFrame: b, at: scheduler.now))
        XCTAssertTrue(cache.undrawnWindows.isEmpty)
        XCTAssertTrue(evictions("").isEmpty)
    }

    /// The reconciler found the window's AX element invalid: its image goes
    /// at once (one line per vanish), the other window keeps flying.
    func testAVanishedWindowLosesItsImageAtOnce() {
        refresh([idA: a, idB: b])
        cache.noteVanished([idB])
        cache.noteVanished([idB])

        XCTAssertNil(cache.flightImage(idB, startFrame: nil, at: scheduler.now))
        XCTAssertNotNil(cache.flightImage(idA, startFrame: a, at: scheduler.now))
        XCTAssertEqual(cache.undrawnWindows, [idB])
        XCTAssertEqual(evictions("reason=vanished"), ["snapshot evict id=2:2 reason=vanished"])
    }

    // MARK: Flight images (SM-11, SM-27)

    func testFlightPrefersTheMatchingSizeAndLogsHowItResizesWithoutStretching() throws {
        refresh([idA: a, idB: b])
        let wide = CGRect(x: 0, y: 100, width: 1600, height: 900)
        XCTAssertEqual(cache.flightImage(idA, startFrame: a.offsetBy(dx: 300, dy: 0), at: scheduler.now)?.otherSize, false)
        let same = try XCTUnwrap(cache.flightImage(idA, startFrame: a, targetFrame: a.offsetBy(dx: 300, dy: 0), at: scheduler.now))
        cache.flies(idA, same, at: scheduler.now)
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot resize") }, "a move resizes nothing")
        let grow = try XCTUnwrap(cache.flightImage(idA, startFrame: a, targetFrame: wide, at: scheduler.now))
        XCTAssertNil(grow.target, "never captured maximized")
        XCTAssertEqual(grow.resize, .fill)
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot resize") }, "a lookup alone logs nothing")
        cache.flies(idA, grow, at: scheduler.now)
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=fill") })
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot scaled") }, "nothing is scaled any more")
        let other = try XCTUnwrap(cache.flightImage(idA, startFrame: wide, at: scheduler.now), "fresh: the other size beats a fallback")
        XCTAssertTrue(other.otherSize)
        XCTAssertEqual(other.resize, .fill)
        scheduler.advance(by: 31)
        XCTAssertNil(cache.flightImage(idA, startFrame: wide, at: scheduler.now), "the other size only while fresh")
        XCTAssertNotNil(cache.flightImage(idA, startFrame: a, at: scheduler.now))
    }

    /// A capture's edge fill is kept with its image; with both sizes the
    /// layer swaps images, and a retarget to a new size is told the face of
    /// that size (or none) and logged once.
    func testCapturedFillsAreKeptAndBothSizesSwap() throws {
        let wide = CGRect(x: 0, y: 100, width: 1600, height: 900)
        let white = ThemeColor(red: 1, green: 1, blue: 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        world.completions.removeLast()(SnapshotCaptureOutcome(
            images: [
                idA: CapturedImage(image: image(), frame: wide, fill: white),
                idB: CapturedImage(image: image(), frame: b),
            ],
            backdrops: [CapturedBackdropImage(image: image(for: screen), displayFrame: screen)]
        ))
        scheduler.runPending()
        XCTAssertEqual(cache.cache.entry(idA)?.fill, white)
        XCTAssertNil(cache.cache.entry(idB)?.fill)
        refresh([idA: a])
        let grow = try XCTUnwrap(cache.flightImage(idA, startFrame: a, targetFrame: wide, at: scheduler.now))
        XCTAssertEqual(grow.target?.fill, white)
        XCTAssertEqual(grow.resize, .swap)
        cache.flies(idA, grow, at: scheduler.now)
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=1:1 mode=swap") })

        let back = cache.retargetFace(idA, image: a.size, from: wide, to: a.offsetBy(dx: 20, dy: 0), at: scheduler.now)
        XCTAssertEqual(back?.size, a.size)
        XCTAssertEqual(world.logs.filter { $0 == (.debug, "snapshot resize id=1:1 mode=swap") }.count, 2)
        let onward = cache.retargetFace(idB, image: b.size, from: b, to: b.offsetBy(dx: 20, dy: 0), at: scheduler.now)
        XCTAssertEqual(onward?.size, b.size, "same size: the face it is fading to, no log")
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("snapshot resize id=2:") })
        let first = cache.retargetFace(idB, image: b.size, from: b, to: wide, at: scheduler.now)
        XCTAssertNil(first, "never captured at that size")
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "snapshot resize id=2:2 mode=fill") })
    }

    // MARK: Close ghost cache (NA-03)

    func testGhostCacheSurvivesTheAxRenderer() {
        refresh([idA: a, idB: b])
        world.rendererAvailable = false
        world.ghostWanted = true
        XCTAssertFalse(cache.rendererUsable(), "no overlay flight with the ax renderer")
        XCTAssertEqual(cache.cache.count, 2, "the ghost keeps its images")
        cache.schedule()
        XCTAssertEqual(scheduler.pendingCount, 1)
    }

    func testGhostOnlyRefreshCapturesJustTheWindowsInView() throws {
        let offscreen = WindowID(pid: 3, elementID: 3)
        let far = CGRect(x: 3000, y: 100, width: 800, height: 900)
        try fixture.session.registry.register(ManagedWindow(
            id: offscreen, pid: 3, application: "App2", title: "secret", frame: far, mode: .tiled
        ))
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.columns.append(Column(id: ColumnID(3), width: 0, windows: [offscreen]))
        fixture.session.manager.update(workspace)
        fixture.physicalFrames[offscreen] = far
        XCTAssertEqual(Set(cache.refreshSet().map(\.id)), [idA, idB, offscreen], "renderer: neighbours too")

        world.rendererAvailable = false
        world.ghostWanted = true
        cache.schedule()
        scheduler.advance(by: 0.3)

        XCTAssertEqual(Set(world.captures.last?.windows.keys ?? [:].keys), [idA, idB])
    }

    // MARK: Invariants

    func testNoTimersAtRest() {
        refresh([idA: a, idB: b])
        cache.noteTyping()
        scheduler.advance(by: snapshotTypingFloor)
        complete([idA: a])
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.advance(by: 600)
        XCTAssertEqual(world.captures.count, 2)
    }

    func testPrefetchOnlyWhenTheManagedSetChanges() {
        cache.prefetchIfNeeded(permissionGranted: true)
        cache.prefetchIfNeeded(permissionGranted: true)
        XCTAssertEqual(world.prefetches, [[idA, idB]], "one prefetch in flight")
        world.prefetchDone.removeFirst()()
        scheduler.runPending()
        cache.prefetchIfNeeded(permissionGranted: true)
        XCTAssertEqual(world.prefetches.count, 1, "same managed set: nothing to fetch")
    }
}
