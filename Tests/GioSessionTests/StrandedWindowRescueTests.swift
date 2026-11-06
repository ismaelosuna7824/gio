@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// FI-16 (live, release v0.1.11): a window on screen was never managed. Its
/// app's Accessibility was not ready for the launch rescue scan nor for the
/// unlock rescan, and nothing asked again. Now a skip or a window the window
/// server lists unregistered is rescanned with backoff until it is
/// registered, gone or given up; wakes rescan again once the screen settles.
final class StrandedWindowRescueTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var rescue: StrandedWindowRescue!
    /// The window server's on-screen layer-0 windows.
    private var server: [ServerWindow] = []
    /// The number each pid's window gets once it is registered.
    private var numbers: [pid_t: UInt32] = [:]
    private var fullRescans = 0

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        server = []
        numbers = [:]
        fullRescans = 0
        var context = world.discoveryContext()
        context.scanFinished = { [unowned self] in rescue.noteScan($0) }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        discovery.syncDisplays()
        let scheduler = scheduler!
        rescue = StrandedWindowRescue(
            context: .init(
                ownPID: EventWorld.ownPID,
                allowsWindowWork: { true },
                isRunning: { [unowned self] in world.running.contains($0) },
                regularPIDs: { [unowned self] in world.running },
                serverWindows: { [unowned self] in server },
                registeredNumbers: { [unowned self] in
                    Set(world.registered.compactMap { numbers[$0.id.pid] })
                },
                scanApp: { [unowned self] in discovery.appAttached($0) },
                rescanAll: { [unowned self] in fullRescans += 1 },
                now: { scheduler.now },
                log: { [unowned self] in world.logs.append(($0, $1)) }
            ),
            scheduler: scheduler
        )
    }

    private var infoLines: [String] {
        world.logs.filter { $0.0 == .info }.map(\.1).filter {
            $0.hasPrefix("window retry") || $0.hasPrefix("session rescan") || $0.hasPrefix("window server stranded")
        }
    }

    private func onScreen(_ pid: pid_t, _ number: UInt32) -> ServerWindow {
        ServerWindow(pid: pid, bounds: CGRect(x: 0, y: 69, width: 1440, height: 900), number: number)
    }

    /// The AX list is readable but empty (the app is not ready); the window
    /// server already shows its window.
    private func strandLoopOps() {
        world.running = [7]
        numbers[7] = 8530
        server = [onScreen(7, 8530)]
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])
    }

    func testASkippedWindowIsRegisteredByALaterRetry() {
        world.running = [7]
        world.scan = SystemWindowDiscoveryResult(windows: [], skipped: 1, skippedPIDs: [7], completePIDs: [])
        discovery.enumerateAndPlace()
        XCTAssertTrue(world.registered.isEmpty)

        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7)], completePIDs: [7])
        scheduler.advance(by: 0.5)

        XCTAssertEqual(world.scans, [nil, 7])
        XCTAssertEqual(world.registered.count, 1)
        XCTAssertEqual(infoLines, ["window retry scan pid=7 attempt=1 reason=skipped"])
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans, [nil, 7], "read fully: the series ended")
    }

    func testTheUnregisteredRescueRetriesUntilTheWindowIsRegistered() {
        strandLoopOps()
        rescue.rescue(7)
        XCTAssertEqual(world.scans, [7], "the window server's rescue scan, as before")

        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.scans, [7, 7])
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7)], completePIDs: [7])
        scheduler.advance(by: 1.5)

        XCTAssertEqual(world.scans, [7, 7, 7])
        XCTAssertEqual(world.registered.count, 1)
        XCTAssertEqual(infoLines, [
            "window retry scan pid=7 attempt=1 reason=unregistered",
            "window retry scan pid=7 attempt=2 reason=unregistered",
        ])
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans.count, 3, "registered: no more scans")
    }

    func testAWindowRegisteredMeanwhileEndsTheSeriesWithoutAScan() {
        strandLoopOps()
        rescue.rescue(7)
        // Another path (an AX event, a full scan) registered it meanwhile.
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7)], completePIDs: [7])
        discovery.enumerateAndPlace()
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans, [7, nil])
    }

    func testAWindowTheWindowServerNoLongerListsEndsTheSeries() {
        strandLoopOps()
        rescue.rescue(7)
        server = []
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans, [7])
    }

    func testTheLastAttemptGivesUp() {
        strandLoopOps()
        rescue.rescue(7)
        for delay in StrandedWindowRetry.delays {
            scheduler.advance(by: delay)
        }

        XCTAssertEqual(world.scans.count, 1 + StrandedWindowRetry.delays.count)
        XCTAssertEqual(infoLines.last, "window retry scan pid=7 gave up attempts=4 reason=unregistered")
        scheduler.advance(by: 120)
        XCTAssertEqual(world.scans.count, 5)
    }

    func testAnAppThatQuitEndsTheSeries() {
        strandLoopOps()
        rescue.rescue(7)
        world.running = []
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans, [7])
        XCTAssertFalse(infoLines.contains { $0.contains("gave up") })
    }

    /// A full scan that registered nothing for an app whose window the
    /// window server shows asks for that app's retries (the safety net).
    func testAFullScanFindsTheStrandedWindowAndRetriesItsApp() {
        strandLoopOps()
        server.append(onScreen(EventWorld.ownPID, 77))
        discovery.enumerateAndPlace()
        XCTAssertEqual(world.scans, [nil])

        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7)], completePIDs: [7])
        scheduler.advance(by: 0.5)

        XCTAssertEqual(world.scans, [nil, 7], "Gio's own window is never asked for")
        XCTAssertEqual(world.registered.count, 1)
        XCTAssertEqual(infoLines, [
            "window server stranded pid=7 windows=1",
            "window retry scan pid=7 attempt=1 reason=unregistered",
        ])
    }

    func testTheSafetyNetRunsEveryThirtySecondsWithoutAFullScan() {
        rescue.start()
        strandLoopOps()
        scheduler.advance(by: StrandedWindowRetry.auditInterval - 1)
        XCTAssertTrue(world.scans.isEmpty)
        scheduler.advance(by: 1)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.scans, [7])
    }

    /// A window admission refuses stays unregistered: after giving up it is
    /// not rescanned by later checks, until its number changes.
    func testARejectedWindowIsNotRescannedForever() {
        strandLoopOps()
        rescue.rescue(7)
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans.count, 5)

        rescue.audit()
        discovery.enumerateAndPlace()
        scheduler.advance(by: 60)
        XCTAssertEqual(world.scans.count, 6, "only the full scan itself")

        server = [onScreen(7, 8531)]
        rescue.audit()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.scans.count, 7, "a new number is a new window")
    }

    func testWakeRescansNowAndAgainOnceTheScreenSettles() {
        rescue.noteWake(reason: "unlock")
        XCTAssertEqual(fullRescans, 1)
        scheduler.advance(by: 2)
        XCTAssertEqual(fullRescans, 2)
        scheduler.advance(by: 4)
        XCTAssertEqual(fullRescans, 3)
        scheduler.advance(by: 60)
        XCTAssertEqual(fullRescans, 3)
        XCTAssertEqual(infoLines, [
            "session rescan reason=unlock",
            "session rescan reason=unlock settle=2s",
            "session rescan reason=unlock settle=6s",
        ])
    }

    func testALaterWakeReplacesThePendingSettleRescans() {
        rescue.noteWake(reason: "wake")
        scheduler.advance(by: 1)
        rescue.noteWake(reason: "unlock")
        scheduler.advance(by: 60)
        XCTAssertEqual(fullRescans, 4, "two immediate rescans, then the unlock's two settles only")
        XCTAssertFalse(infoLines.contains("session rescan reason=wake settle=2s"))
    }

    /// What gave up behind the lock may answer after it.
    func testAWakeForgetsTheRejectedWindows() {
        strandLoopOps()
        rescue.rescue(7)
        scheduler.advance(by: 60)
        rescue.noteWake(reason: "unlock")
        rescue.audit()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.scans.count, 6)
    }
}
