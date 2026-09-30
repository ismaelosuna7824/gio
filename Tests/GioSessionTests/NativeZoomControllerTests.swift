import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

final class NativeZoomControllerTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var shuttingDown = false
        var motion = false
        var flight = false
        var enabled = true
        var snapshotRenderer = false
        var physical: [WindowID: CGRect] = [:]
        var trustEvents: [String] = []
        var echoes: [(WindowID, CGRect)] = []
        var windowServerID: UInt32? = 42
        var bounds: CGRect?
        var boundsQueries = 0
        var availability: ZoomAvailability = .available
        var press: ZoomPressResult = .pressed
        var presses = 0
        var reasserts: [(WindowID, CGRect)] = []
        var reassertFails: Bool? = false
        var dimUpdates = 0
        var instantReflows = 0
        var logs: [(LogLevel, String)] = []
    }

    private let start = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let target = CGRect(x: 10, y: 10, width: 1780, height: 1100)
    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private var world: World!
    private var fixture: SessionFixture!
    private var scheduler: ManualScheduler!
    private var zoom: NativeZoomController!
    private var id: WindowID!

    override func setUp() {
        world = World()
        fixture = SessionFixture(frames: [start], focus: 0)
        id = SessionFixture.id(0, pid: 1)
        world.physical[id] = start
        scheduler = ManualScheduler()
        let world = world!
        let scheduler = scheduler!
        zoom = NativeZoomController(
            context: .init(
                isShuttingDown: { world.shuttingDown },
                isMotionActive: { world.motion },
                isFlightActive: { world.flight },
                isEnabled: { world.enabled },
                snapshotRendererUsable: { world.snapshotRenderer },
                physicalFrame: { world.physical[$0] },
                setPhysicalFrame: { world.physical[$0] = $1 },
                invalidateTrust: { world.trustEvents.append("invalidate \($0.elementID)") },
                trust: { id, _ in world.trustEvents.append("trust \(id.elementID)") },
                recordEcho: { id, frame, _ in world.echoes.append((id, frame)) },
                windowServerID: { _, _ in world.windowServerID },
                windowServerBounds: { _ in
                    world.boundsQueries += 1
                    return world.bounds
                },
                zoomAvailability: { _ in world.availability },
                pressZoom: { _ in
                    world.presses += 1
                    return world.press
                },
                reassert: { id, frame in
                    world.reasserts.append((id, frame))
                    return world.reassertFails
                },
                updateDim: { world.dimUpdates += 1 },
                instantReflow: { world.instantReflows += 1 },
                appName: { "App\($0)" },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            scheduler: scheduler
        )
    }

    private var growing: WindowAnimation {
        WindowAnimation(id: id, from: start, to: target, duration: 0.3)
    }

    private func lines(containing text: String) -> [String] {
        world.logs.map(\.1).filter { $0.contains(text) }
    }

    /// Toggle maximize, plan and press: the zoom is in flight.
    private func pressMaximize() throws -> NativeZoomController.Job {
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        let job = try XCTUnwrap(zoom.plan(animations: [growing], animating: true))
        XCTAssertEqual(job.action, .maximize)
        XCTAssertEqual(job.windowID, 42)
        world.bounds = start
        zoom.start(job)
        return job
    }

    /// Resolve the zoom at `frame` (bounds change, then quiet).
    private func settle(at frame: CGRect) throws -> NativeZoomResolution {
        _ = try pressMaximize()
        world.bounds = frame
        scheduler.advance(by: 0.5)
        var resolved = zoom.takeResolved()
        XCTAssertEqual(resolved.count, 1)
        return resolved.removeFirst()
    }

    private func judge(_ resolution: NativeZoomResolution) {
        var pending = [resolution]
        zoom.judge(&pending, plan: ParkingPlan(visible: [id: target]), viewport: viewport)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Press and settle

    func testPendingPressSettlesAfterTheQuietPeriodOverMultipleStages() throws {
        world.press = .pending(code: -25204)
        _ = try pressMaximize()
        XCTAssertTrue(zoom.isInFlight(id))
        XCTAssertTrue(zoom.isBusy(id))
        XCTAssertTrue(world.trustEvents.contains("invalidate 1"))
        XCTAssertEqual(lines(containing: "press pending").count, 1)
        XCTAssertEqual(world.boundsQueries, 1, "one lookup of the start bounds at plan time")

        // Two stages of the app's own animation, then quiet.
        scheduler.advance(by: 0.05)
        world.bounds = CGRect(x: 60, y: 60, width: 1200, height: 900)
        scheduler.advance(by: 0.1)
        world.bounds = target
        scheduler.advance(by: 0.14)
        XCTAssertTrue(zoom.isInFlight(id), "still inside the quiet period")
        scheduler.advance(by: 0.03)
        XCTAssertFalse(zoom.isInFlight(id))
        XCTAssertTrue(zoom.isBusy(id), "resolved, waiting for the verdict")
        XCTAssertEqual(world.instantReflows, 1, "at rest one instant pass judges it")

        let resolved = zoom.takeResolved()
        guard case .settled(let frame, _, let settleMs?)? = resolved.first?.settle else {
            return XCTFail("the zoom settled")
        }
        XCTAssertEqual(frame, target)
        XCTAssertEqual(settleMs, 160)
        let queries = world.boundsQueries
        scheduler.advance(by: 1)
        XCTAssertEqual(world.boundsQueries, queries, "the poller stopped with the settle")
    }

    func testSettleDuringMotionWaitsForTheFinalPass() throws {
        world.motion = true
        _ = try pressMaximize()
        world.bounds = target
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.instantReflows, 0)
        XCTAssertTrue(zoom.isBusy(id))
    }

    func testUnchangedBoundsTimeOut() throws {
        _ = try pressMaximize()
        scheduler.advance(by: NativeZoomLimits.settleTimeout + 0.05)
        guard case .unchanged? = zoom.takeResolved().first?.settle else {
            return XCTFail("nothing moved: unchanged")
        }
    }

    func testFailedPressFallsBackAtOnce() throws {
        world.press = .failed(code: -25200)
        let resolution = try settle(at: start)
        XCTAssertEqual(resolution.settle, .pressFailed(code: -25200))
        judge(resolution)
        XCTAssertEqual(lines(containing: "result=fallback(pressFailed:-25200)").count, 1)
        zoom.scheduleVerifications(failed: [])
        XCTAssertFalse(zoom.isBusy(id))
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: Verdicts

    func testExactZoomIsAcceptedWithoutAVerification() throws {
        judge(try settle(at: target))
        XCTAssertEqual(lines(containing: "result=exact").count, 1)
        XCTAssertTrue(lines(containing: "result=exact").first!.hasSuffix("verified=true"))
        XCTAssertEqual(world.trustEvents.last, "trust 1")
        XCTAssertEqual(world.physical[id], target)
        XCTAssertFalse(zoom.isBusy(id))
        XCTAssertFalse(zoom.isActive)
        let accepted = CGRect(x: 10, y: 10, width: 1780, height: 1100)
        XCTAssertEqual(zoom.applyAccepted(to: [id: target], parked: [])[id], accepted)
        zoom.scheduleVerifications(failed: [])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testCorrectedZoomIsVerifiedAfterTheWrite() throws {
        let near = target.insetBy(dx: 20, dy: 20)
        judge(try settle(at: near))
        XCTAssertTrue(zoom.isBusy(id), "verifying: events stay suppressed")
        XCTAssertTrue(zoom.isActive)
        XCTAssertTrue(nativeZoomDropsEvent(.moved, inFlight: zoom.isBusy(id)))
        // The ordinary pass wrote the target.
        world.physical[id] = target
        world.bounds = target
        zoom.scheduleVerifications(failed: [])
        scheduler.advance(by: NativeZoomLimits.verifyDelay)
        let line = try XCTUnwrap(lines(containing: "result=corrected").first)
        XCTAssertTrue(line.hasSuffix("verified=true"))
        XCTAssertFalse(zoom.isBusy(id))
        XCTAssertFalse(nativeZoomDropsEvent(.moved, inFlight: zoom.isBusy(id)))
        XCTAssertEqual(world.dimUpdates, 1)
        XCTAssertTrue(world.reasserts.isEmpty)
    }

    func testOverwrittenCorrectionIsReassertedOnce() throws {
        let near = target.insetBy(dx: 20, dy: 20)
        judge(try settle(at: near))
        world.physical[id] = target
        // The app's zoom keeps its own frame over Gio's write.
        world.bounds = near
        zoom.scheduleVerifications(failed: [])
        scheduler.advance(by: NativeZoomLimits.verifyDelay)
        XCTAssertEqual(world.reasserts.count, 1)
        XCTAssertEqual(lines(containing: "reassert id=1:1 app=App1 reason=overwritten").count, 1)
        XCTAssertEqual(world.echoes.last?.1, target)
        scheduler.advance(by: NativeZoomLimits.verifyDelay)
        XCTAssertEqual(world.reasserts.count, 1, "at most one reassert")
        XCTAssertTrue(try XCTUnwrap(lines(containing: "result=corrected").first).hasSuffix("verified=false"))
        XCTAssertFalse(zoom.isBusy(id))
    }

    func testFailedCorrectingWriteIsReassertedAsWriteFailed() throws {
        judge(try settle(at: target.insetBy(dx: 20, dy: 20)))
        world.bounds = target.insetBy(dx: 20, dy: 20)
        zoom.scheduleVerifications(failed: [id])
        scheduler.advance(by: NativeZoomLimits.verifyDelay)
        XCTAssertEqual(lines(containing: "reason=writeFailed").count, 1)
    }

    func testMismatchFallsBackAndIsVerified() throws {
        judge(try settle(at: CGRect(x: 300, y: 300, width: 900, height: 700)))
        XCTAssertTrue(zoom.isBusy(id))
        world.physical[id] = target
        world.bounds = target
        zoom.scheduleVerifications(failed: [])
        scheduler.advance(by: NativeZoomLimits.verifyDelay)
        XCTAssertTrue(
            try XCTUnwrap(lines(containing: "result=fallback(mismatch)").first).hasSuffix("verified=true")
        )
    }

    func testUnjudgedZoomIsLoggedNotVisible() throws {
        let resolution = try settle(at: target)
        var pending = [resolution]
        zoom.judge(&pending, plan: ParkingPlan(), viewport: viewport)
        XCTAssertEqual(pending.count, 1)
        zoom.dropUnjudged(pending)
        XCTAssertEqual(lines(containing: "result=fallback(notVisible)").count, 1)
        XCTAssertNil(world.physical[id])
    }

    // MARK: Restore and skips

    func testRestoreOfANativeMaximizeUsesTheZoom() throws {
        judge(try settle(at: target))
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.columns[0].savedWidthSpec = .standard
        zoom.requestToggle(in: workspace)
        let job = try XCTUnwrap(zoom.plan(animations: [], animating: true))
        XCTAssertEqual(job.action, .restore)
    }

    func testRestoreWithoutNativeMaximizeIsSkipped() {
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.columns[0].savedWidthSpec = .standard
        zoom.requestToggle(in: workspace)
        XCTAssertNil(zoom.plan(animations: [], animating: true))
        XCTAssertEqual(lines(containing: "reason=notNativeMaximized").count, 1)
    }

    func testSnapshotRendererOrInstantPassSkipsTheZoom() {
        world.snapshotRenderer = true
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        XCTAssertNil(zoom.plan(animations: [growing], animating: true))
        world.snapshotRenderer = false
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        XCTAssertNil(zoom.plan(animations: [growing], animating: false))
        XCTAssertEqual(lines(containing: "reason=noAxMotion").count, 2)
        XCTAssertNil(zoom.plan(animations: [growing], animating: true), "the request is consumed")
    }

    func testUnavailableZoomAndMissingWindowFallBack() {
        world.availability = .unavailable("no button")
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        XCTAssertNil(zoom.plan(animations: [growing], animating: true))
        XCTAssertEqual(lines(containing: "result=fallback(unavailable)").count, 1)
        world.availability = .available
        world.windowServerID = nil
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        XCTAssertNil(zoom.plan(animations: [growing], animating: true))
        XCTAssertEqual(lines(containing: "result=fallback(noWindowServer)").count, 1)
        XCTAssertFalse(zoom.isBusy(id))
    }

    func testBusyWindowIgnoresAnotherToggle() throws {
        _ = try pressMaximize()
        zoom.requestToggle(in: fixture.session.manager.currentWorkspace())
        XCTAssertNil(zoom.plan(animations: [growing], animating: true))
        XCTAssertEqual(world.presses, 1)
    }

    func testPurgeStopsThePollerAndTheHold() throws {
        _ = try pressMaximize()
        zoom.purge(id)
        XCTAssertFalse(zoom.isBusy(id))
        XCTAssertFalse(zoom.isActive)
        let queries = world.boundsQueries
        scheduler.advance(by: 1)
        XCTAssertEqual(world.boundsQueries, queries)
        XCTAssertEqual(world.dimUpdates, 1)
    }

    func testNoPollingAtRest() throws {
        judge(try settle(at: target))
        let queries = world.boundsQueries
        scheduler.advance(by: 10)
        XCTAssertEqual(world.boundsQueries, queries)
    }
}
