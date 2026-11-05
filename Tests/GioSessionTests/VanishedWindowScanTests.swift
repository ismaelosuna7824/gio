@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// SM-31: a window the reconciler found with an invalid AX element
/// (`ReconcileReport.vanished`) is not purged on that alone (absence is not
/// death); one complete scan of its pid, on the next turn of the session
/// queue, proves it gone. One scan per window per vanish, never a storm.
final class VanishedWindowScanTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        discovery = DiscoveryService(context: world.discoveryContext(), scheduler: scheduler)
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        world.session.config.workspaces = [WorkspaceDefinition(name: "Chat")]
        discovery.syncDisplays()
    }

    /// Registers `windows` with a full scan and returns their ids in order;
    /// the scan log and reflow count start over.
    private func register(_ windows: [DiscoveredSystemWindow]) -> [WindowID] {
        let pids = Set(windows.map(\.window.pid))
        world.scan = SystemWindowDiscoveryResult(windows: windows, completePIDs: pids)
        world.running = pids
        discovery.enumerateAndPlace()
        world.scans = []
        world.reflows = 0
        return windows.compactMap { world.known($0.element) }
    }

    func testAVanishedWindowIsPurgedByOneScanOfItsPidThatNoLongerListsIt() {
        let kept = discovered(pid: 7)
        let gone = discovered(pid: 7)
        let ids = register([kept, gone, discovered(pid: 8)])
        world.scan = SystemWindowDiscoveryResult(windows: [kept], completePIDs: [7])

        discovery.noteSettled(vanished: [ids[1]], alive: [ids[0], ids[2]])
        XCTAssertTrue(world.scans.isEmpty, "never inside the settle that reported it")
        scheduler.runPending()

        XCTAssertEqual(world.scans, [7], "its pid only")
        XCTAssertEqual(world.forgotten, [ids[1]])
        XCTAssertEqual(Set(world.registered.map(\.id)), [ids[0], ids[2]])
        XCTAssertEqual(world.reflows, 1, "the gap closes")
    }

    func testAnIncompleteScanProvesNothingAndTheVanishIsNotScannedAgain() {
        let ids = register([discovered(pid: 7)])
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [])

        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()
        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()

        XCTAssertEqual(world.scans, [7], "one scan per vanish, however many passes report it")
        XCTAssertEqual(world.registered.map(\.id), ids, "absence from a partial read is not death")
        XCTAssertEqual(world.reflows, 0, "nothing changed")

        // It settled again, then vanished again: a new vanish.
        discovery.noteSettled(vanished: [], alive: ids)
        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()
        XCTAssertEqual(world.scans, [7, 7])
    }

    func testWindowsOfOnePidVanishingTogetherShareOneScan() {
        let ids = register([discovered(pid: 7), discovered(pid: 7), discovered(pid: 8)])
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7, 8])

        discovery.noteSettled(vanished: [ids[0]], alive: [])
        discovery.noteSettled(vanished: [ids[1], ids[2]], alive: [])
        scheduler.runPending()

        XCTAssertEqual(world.scans.compactMap { $0 }.sorted(), [7, 8])
        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.reflows, 1, "one relayout for the whole batch")
    }

    func testAnUnregisteredOrPurgedWindowIsNeverScannedFor() {
        let ids = register([discovered(pid: 7)])
        discovery.purge(ids)

        discovery.noteSettled(vanished: ids + [WindowID(pid: 9, elementID: 99)], alive: [])
        scheduler.runPending()

        XCTAssertTrue(world.scans.isEmpty)
    }

    /// The proof scan is not an arrival: a window it finds is placed like a
    /// full scan's, and never takes the user to its workspace.
    func testANewWindowTheScanFindsNeverTakesTheUserAlong() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .always)]
        let ids = register([discovered(pid: 7, app: "Mail")])
        world.frontmost = 7
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7, app: "Mail")], completePIDs: [7])

        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()

        XCTAssertEqual(world.registered.count, 1, "the vanished one purged, the new one registered")
        XCTAssertFalse(world.registered.contains { $0.id == ids[0] })
        XCTAssertTrue(world.follows.isEmpty)
    }

    /// FI-15 (live, screen lock): the reconciler reports every window
    /// vanished and the proof scan reads apps whose lists hold no window,
    /// yet the window server still lists their numbers. Kept, not purged.
    func testAWindowTheWindowServerStillListsSurvivesAnEmptyProofScan() {
        let ids = register([discovered(pid: 7), discovered(pid: 7)])
        world.windowNumbers = [ids[0]: 41, ids[1]: 42]
        world.liveNumbers = [41, 42, 500]
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])

        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()

        XCTAssertEqual(Set(world.registered.map(\.id)), Set(ids))
        XCTAssertTrue(world.forgotten.isEmpty)
        XCTAssertEqual(world.liveNumberQueries, 1, "one window-server query per purge batch")
        XCTAssertEqual(world.reflows, 0, "nothing changed")
        let kept = world.logs.map(\.1).filter { $0.hasPrefix("window kept") }
        XCTAssertEqual(kept, ids.map { "window kept id=\($0.pid):\($0.elementID) reason=window-server-alive" })
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("window vanished scan pids=1 purged=0 ") })

        // Later the window server drops them too: the next scan purges them.
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])
        world.liveNumbers = [500]
        discovery.enumerateAndPlace()
        XCTAssertTrue(world.registered.isEmpty, "once the window server drops them, the scan purges them")
    }

    func testAWindowWithoutARecordedNumberIsPurgedAsBefore() {
        let ids = register([discovered(pid: 7)])
        world.liveNumbers = [41]
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])

        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.liveNumberQueries, 0, "no number, nothing to ask")
    }

    /// A destroyed notice is the window server's own proof: its proof scan
    /// purges even a window already kept once (its vanish was scanned).
    func testADestroyedNoticeStillRemovesTheWindow() {
        let ids = register([discovered(pid: 7)])
        world.windowNumbers = [ids[0]: 41]
        world.liveNumbers = [41]
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])
        discovery.noteSettled(vanished: ids, alive: [])
        scheduler.runPending()
        XCTAssertEqual(world.registered.map(\.id), ids, "kept during the lock")

        discovery.noteDestroyed(ids[0])
        scheduler.runPending()

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.forgotten, ids)
        XCTAssertEqual(world.reflows, 1)
    }

    /// A destroyed window the app still lists (a tab, a reopened element)
    /// stays, and its notice does not outlive the scan.
    func testADestroyedNoticeForAListedWindowPurgesNothing() {
        let window = discovered(pid: 7)
        let ids = register([window])
        world.windowNumbers = [ids[0]: 41]
        world.liveNumbers = [41]
        world.scan = SystemWindowDiscoveryResult(windows: [window], completePIDs: [7])

        discovery.noteDestroyed(ids[0])
        scheduler.runPending()
        XCTAssertEqual(world.registered.map(\.id), ids)

        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])
        discovery.enumerateAndPlace()
        XCTAssertEqual(world.registered.map(\.id), ids, "the old notice proves nothing now")
    }
}
