import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

final class FakeOverlay: OverlayPort, @unchecked Sendable {
    var begins: [(token: Int, flights: [OverlayFlight])] = []
    var retargets: [(token: Int, targets: [WindowID: CGRect], adds: [OverlayFlight])] = []
    var ends: [Bool] = []
    var backdropReady = true

    func beginFlight(token: Int, spring: SpringParameters, flights: [OverlayFlight]) {
        begins.append((token, flights))
    }

    func retargetFlight(token: Int, targets: [WindowID: CGRect], adds: [OverlayFlight]) {
        retargets.append((token, targets, adds))
    }

    func endFlight(fadeOut: Bool) {
        ends.append(fadeOut)
    }

    func hasBackdrop(for displayFrame: CGRect) -> Bool {
        backdropReady
    }
}

final class SnapshotFlightTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var rendererAvailable = true
        var ghostWanted = false
        var motion = false
        var shuttingDown = false
        var coalesced = false
        var reflows = 0
        var ringPublishes = 0
        var renderChecks = 0
        var captures: [SnapshotCaptureRequest] = []
        var completions: [@Sendable ([WindowID: CapturedImage]) -> Void] = []
        var prefetches: [Set<WindowID>] = []
        var prefetchDone: [@Sendable () -> Void] = []
        var logs: [(LogLevel, String)] = []
    }

    private let a = CGRect(x: 0, y: 100, width: 800, height: 900)
    private let b = CGRect(x: 820, y: 100, width: 800, height: 900)
    private var world: World!
    private var fixture: SessionFixture!
    private var scheduler: ManualScheduler!
    private var overlay: FakeOverlay!
    private var cache: SnapshotCacheRefresher!
    private var flight: SnapshotFlightController!
    private var idA: WindowID!
    private var idB: WindowID!

    override func setUp() {
        world = World()
        fixture = SessionFixture(frames: [a, b], focus: 0)
        scheduler = ManualScheduler()
        overlay = FakeOverlay()
        idA = SessionFixture.id(0, pid: 1)
        idB = SessionFixture.id(1, pid: 2)
        let world = world!
        let fixture = fixture!
        let scheduler = scheduler!
        cache = SnapshotCacheRefresher(
            context: .init(
                session: { fixture.session },
                displays: { fixture.displays.allDisplays() },
                physicalFrame: { fixture.physicalFrames[$0] },
                isShuttingDown: { world.shuttingDown },
                isFlightActive: { [unowned self] in flight.isActive },
                isMotionActive: { world.motion },
                rendererAvailable: { world.rendererAvailable },
                ghostCacheWanted: { world.ghostWanted },
                captureScreens: {
                    ([SnapshotDisplay(id: 1, frame: SessionFixture.screen, scale: 1)], SessionFixture.screen.height)
                },
                capture: { request, done in
                    world.captures.append(request)
                    world.completions.append(done)
                },
                prefetch: { managed, done in
                    world.prefetches.append(managed)
                    world.prefetchDone.append(done)
                },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            scheduler: scheduler
        )
        flight = SnapshotFlightController(
            context: .init(
                displayFrames: { fixture.displays.allDisplays().map(\.frame) },
                physicalFrames: { fixture.physicalFrames },
                isShuttingDown: { world.shuttingDown },
                takeCoalescedReflow: {
                    defer { world.coalesced = false }
                    return world.coalesced
                },
                performReflow: { world.reflows += 1 },
                publishFocusRing: { world.ringPublishes += 1 },
                scheduleRenderCheck: { world.renderChecks += 1 },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            cache: cache, overlay: overlay, scheduler: scheduler
        )
    }

    private func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Runs one refresh and completes its capture with `images`.
    private func refresh(_ images: [WindowID: CGRect]) {
        cache.schedule()
        scheduler.advance(by: 0.3)
        let done = world.completions.removeLast()
        done(images.mapValues { CapturedImage(image: image(), frame: $0) })
        scheduler.runPending()
    }

    private func slide(_ id: WindowID, from: CGRect, by dx: CGFloat) -> (WindowAnimation, ParkingPlan) {
        let to = from.offsetBy(dx: dx, dy: 0)
        var visible = fixture.physicalFrames
        visible[id] = to
        return (WindowAnimation(id: id, from: from, to: to, duration: 0.3), ParkingPlan(visible: visible))
    }

    // MARK: Flight

    func testFlightSettlesOnlyWhenLayersAndPassBothFinished() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)

        XCTAssertTrue(flight.drive(animations: [animation], plans: [plan], spring: .niri))
        XCTAssertTrue(flight.isActive)
        XCTAssertEqual(overlay.begins.map(\.token), [1])
        XCTAssertEqual(overlay.begins.first?.flights.first?.items.map(\.id).sorted(), [idA, idB])

        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertTrue(flight.isActive, "the final pass has not settled yet")
        XCTAssertTrue(overlay.ends.isEmpty)

        flight.passSettled()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, [true])
        XCTAssertEqual(world.ringPublishes, 1)
        XCTAssertEqual(world.renderChecks, 1)
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("snapshot flight layers=2") })
        XCTAssertEqual(scheduler.pendingCount, 1, "one cache refresh after the settle")
    }

    func testStaleTokenDoesNotSettle() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertTrue(flight.drive(animations: [animation], plans: [plan], spring: .niri))
        flight.passSettled()
        flight.layersFinished(7)
        scheduler.runPending()
        XCTAssertTrue(flight.isActive)
    }

    func testAbortFromTheOverlayClearsWithoutFadeAndRefreshes() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertTrue(flight.drive(animations: [animation], plans: [plan], spring: .niri))

        flight.aborted(.mouseDown)
        XCTAssertTrue(flight.isActive, "the abort hops onto the session queue")
        scheduler.runPending()

        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(overlay.ends.isEmpty, "the overlay already came down itself")
        XCTAssertEqual(world.ringPublishes, 1)
        XCTAssertEqual(world.renderChecks, 1)
        XCTAssertTrue(world.logs.contains { $0.1 == snapshotAbortLine(reason: .mouseDown) })
        // The old token is dead: late layers do not settle anything.
        flight.layersFinished(1)
        scheduler.runPending()
        XCTAssertTrue(overlay.ends.isEmpty)
    }

    func testEndAndDisplayChangeBringTheOverlayDown() {
        refresh([idA: a, idB: b])
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertTrue(flight.drive(animations: [animation], plans: [plan], spring: .niri))
        flight.abortForDisplayChange()
        XCTAssertFalse(flight.isActive)
        XCTAssertEqual(overlay.ends, [false])
        XCTAssertTrue(world.logs.contains { $0.1 == snapshotAbortLine(reason: .displayChange) })
        flight.end(fadeOut: true)
        XCTAssertEqual(overlay.ends, [false], "nothing to end without a flight")
    }

    func testRetargetReusesTheRunningFlight() {
        refresh([idA: a, idB: b])
        let (first, plan) = slide(idA, from: a, by: 100)
        XCTAssertTrue(flight.drive(animations: [first], plans: [plan], spring: .niri))
        let (second, plan2) = slide(idA, from: a.offsetBy(dx: 100, dy: 0), by: 100)

        XCTAssertTrue(flight.drive(animations: [second], plans: [plan2], spring: .niri))

        XCTAssertEqual(overlay.begins.count, 1)
        XCTAssertEqual(overlay.retargets.map(\.token), [2])
        XCTAssertEqual(overlay.retargets.first?.targets[idA], second.to)
        XCTAssertTrue(overlay.retargets.first?.adds.isEmpty == true)
        // The retarget's token is the one that settles.
        flight.layersFinished(1)
        flight.layersFinished(2)
        scheduler.runPending()
        flight.passSettled()
        XCTAssertEqual(overlay.ends, [true])
    }

    func testCacheMissFallsBackAndRefreshesSoon() {
        refresh([idA: a])
        let (animation, plan) = slide(idA, from: a, by: 100)

        XCTAssertFalse(flight.drive(animations: [animation], plans: [plan], spring: .niri))

        XCTAssertFalse(flight.isActive)
        XCTAssertTrue(overlay.begins.isEmpty)
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot fallback reason=cache-miss ids=1" })
        scheduler.advance(by: 0.05)
        XCTAssertEqual(world.captures.count, 2, "a refresh 50 ms later")
    }

    func testMissingBackdropFallsBack() {
        refresh([idA: a, idB: b])
        overlay.backdropReady = false
        let (animation, plan) = slide(idA, from: a, by: 100)
        XCTAssertFalse(flight.drive(animations: [animation], plans: [plan], spring: .niri))
        XCTAssertTrue(world.logs.contains { $0.1 == "snapshot fallback reason=no-backdrop ids=0" })
    }

    func testBurstDuringFlightMergesIntoOneReflow() {
        world.coalesced = true
        flight.scheduleReflow()
        flight.scheduleReflow()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: SnapshotFlightController.retargetDelay)
        XCTAssertEqual(world.reflows, 1)
        // Nothing coalesced: no reflow.
        flight.scheduleReflow()
        scheduler.advance(by: SnapshotFlightController.retargetDelay)
        XCTAssertEqual(world.reflows, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: Cache refresh

    func testRefreshIsDebouncedToTheLatestRequest() {
        cache.schedule()
        scheduler.advance(by: 0.1)
        cache.schedule()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.captures.count, 1)
        XCTAssertEqual(Set(world.captures[0].windows.keys), [idA, idB])
        XCTAssertFalse(world.captures[0].includeBackdrop)
    }

    func testRefreshWhileBusyRunsOnceMoreAfterTheCapture() {
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1)
        cache.schedule()
        scheduler.advance(by: 0.3)
        XCTAssertEqual(world.captures.count, 1, "busy: remembered, not started")

        world.completions.removeFirst()([idA: CapturedImage(image: image(), frame: a)])
        scheduler.runPending()
        scheduler.advance(by: 0.05)
        XCTAssertEqual(world.captures.count, 2)
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
        refresh([idA: a])
        XCTAssertEqual(cache.cache.ids, [idA])
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("snapshot cache entries=1") })
    }

    func testUnusableRendererDropsTheCacheAndSchedulesNothing() {
        refresh([idA: a, idB: b])
        world.rendererAvailable = false
        XCTAssertFalse(cache.rendererUsable())
        XCTAssertEqual(cache.cache.count, 0)
        cache.schedule()
        XCTAssertEqual(scheduler.pendingCount, 0)
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

    func testNoTimersAtRest() {
        refresh([idA: a, idB: b])
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.advance(by: 60)
        XCTAssertEqual(world.captures.count, 1)
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
