@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// Registration retries run only for a real, running app other than Gio,
/// carry the pid the created event came from, and log to the sink the
/// context injects (never the user's real log file: the `pid=7` retry lines
/// found in `~/.config/gio/gio.log` were this test fixture's pid, written by
/// `swift test` while Gio was not running).
final class RegistrationRetryGuardTests: XCTestCase {
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
        discovery.syncDisplays()
    }

    private func lines(_ prefix: String) -> [(LogLevel, String)] {
        world.logs.filter { $0.1.hasPrefix(prefix) }
    }

    func testDiscoveryLogsGoToTheInjectedSink() {
        world.running = [7]
        world.classify[7] = [nil, discovered(pid: 7)]

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)

        XCTAssertEqual(lines("window register retry pid=7 attempt=1").count, 1, "\(world.logs)")
    }

    func testRetryCarriesTheEventPid() {
        world.running = [4321]
        var context = world.discoveryContext()
        var asked: [pid_t] = []
        var attempts: [SingleWindowDiscovery] = [.unclassified, .found(discovered(pid: 4321))]
        context.discoverAttempt = { _, pid in
            asked.append(pid)
            return attempts.removeFirst()
        }
        discovery = DiscoveryService(context: context, scheduler: scheduler)

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 4321)
        scheduler.advance(by: 0.1)

        XCTAssertEqual(asked, [4321, 4321])
        XCTAssertEqual(lines("window register retry pid=4321 attempt=1").count, 1, "\(world.logs)")
        XCTAssertEqual(world.registered.map(\.pid), [4321])
    }

    func testNoRetryForAPidThatIsNotARunningApp() {
        world.running = []
        world.classify[4321] = [nil, discovered(pid: 4321)]

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 4321)
        scheduler.advance(by: 5)

        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertTrue(lines("window register retry").isEmpty, "\(world.logs)")
        let dropped = lines("window register dropped")
        XCTAssertEqual(dropped.map(\.1), ["window register dropped pid=4321 reason=notRunning attempts=1"])
        XCTAssertEqual(dropped.map(\.0), [.debug])
    }

    func testOwnPidIsNeverClassifiedNorRetried() {
        world.running = [EventWorld.ownPID]
        var context = world.discoveryContext()
        var asked: [pid_t] = []
        context.discoverAttempt = { _, pid in
            asked.append(pid)
            return .unclassified
        }
        discovery = DiscoveryService(context: context, scheduler: scheduler)

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: EventWorld.ownPID)
        scheduler.advance(by: 5)

        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(world.logs.isEmpty, "\(world.logs)")
    }
}
