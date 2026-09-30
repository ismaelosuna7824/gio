@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// NW-06: with `follow = "when-active"`, an arrival whose app is not
/// frontmost still takes the user to its named workspace when the app was
/// launched moments ago, or when the app becomes active shortly after its
/// window was placed, unless the user moved meanwhile or the window closed.
/// Fake clock and frontmost pid; no desktop is touched.
final class DeferredFollowTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var clock: TimeInterval = 100

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        var context = world.discoveryContext()
        context.now = { [unowned self] in clock }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        world.session.config.workspaces = [WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Web")]
        discovery.syncDisplays()
        world.session.manager.switchTo(1)
        world.running = [7]
        world.frontmost = 99
    }

    private var manager: WorkspaceManager { world.session.manager }

    private func rule(_ follow: WorkspaceFollowPolicy) {
        world.session.config.rules = [WindowRule(app: "Brave", openOnWorkspace: "Web", follow: follow)]
    }

    @discardableResult
    private func arrive(pid: pid_t = 7) -> WindowID? {
        let before = Set(world.registered.map(\.id))
        world.classify[pid] = [discovered(pid: pid, app: "Brave")]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: pid)
        return world.registered.map(\.id).first { !before.contains($0) }
    }

    private func deferredLines() -> [String] {
        world.logs.map(\.1).filter { $0.hasPrefix("window follow deferred") }
    }

    func testRecentlyLaunchedAppFollowsWhenNotFrontmost() throws {
        rule(.whenActive)
        discovery.appLaunched(7)
        clock += 2

        let id = try XCTUnwrap(arrive())

        XCTAssertEqual(manager.currentWorkspace().name, "Web")
        XCTAssertEqual(world.follows.count, 1)
        XCTAssertEqual(deferredLines(), ["window follow deferred id=\(id.pid):\(id.elementID) reason=launched"])
    }

    func testLateActivationWithinTheWindowFollows() throws {
        rule(.whenActive)
        let id = try XCTUnwrap(arrive())
        XCTAssertEqual(manager.currentWorkspace().name, "Code", "placed silently at registration")
        let reflowsBefore = world.reflows

        clock += 1
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Web")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow, id)
        XCTAssertEqual(world.follows.count, 1)
        XCTAssertEqual(world.reflows, reflowsBefore + 1)
        XCTAssertEqual(deferredLines(), ["window follow deferred id=\(id.pid):\(id.elementID) reason=activated"])
    }

    func testActivationAfterTheDeadlineDoesNotFollow() {
        rule(.whenActive)
        arrive()
        clock += 1.6
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testUserSwitchingWorkspaceMeanwhileCancels() {
        rule(.whenActive)
        arrive()
        world.session.manager.switchTo(3)
        clock += 0.5
        discovery.appActivated(7)

        XCTAssertNotEqual(manager.currentWorkspace().name, "Web")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testUserFocusChangeMeanwhileCancels() {
        rule(.whenActive)
        world.classify[5] = [discovered(pid: 5, app: "Code")]
        world.running.insert(5)
        discovery.registerAppeared(AXUIElementCreateApplication(4000), pid: 5)
        world.classify[6] = [discovered(pid: 6, app: "Code")]
        world.running.insert(6)
        discovery.registerAppeared(AXUIElementCreateApplication(4001), pid: 6)
        arrive()
        // The user clicks the other window of the current workspace.
        var current = manager.currentWorkspace()
        let other = current.columns.flatMap(\.windows).first { $0 != current.focusedWindow }!
        current = adoptingFocus(other, in: current)!
        world.session.manager.update(current)

        clock += 0.5
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testClosedWindowCancels() throws {
        rule(.whenActive)
        let id = try XCTUnwrap(arrive())
        discovery.purge([id])
        clock += 0.5
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testNeverIsUnaffectedByLaunchAndActivation() {
        rule(.never)
        discovery.appLaunched(7)
        arrive()
        clock += 0.5
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertTrue(world.follows.isEmpty)
        XCTAssertTrue(deferredLines().isEmpty)
    }

    func testAlwaysFollowsAtOnceAndLogsNoDeferral() {
        rule(.always)
        arrive()
        XCTAssertEqual(manager.currentWorkspace().name, "Web")
        clock += 0.5
        discovery.appActivated(7)
        XCTAssertEqual(world.follows.count, 1)
        XCTAssertTrue(deferredLines().isEmpty)
    }

    func testStartupScanNeverDefersAFollow() {
        rule(.whenActive)
        discovery.appLaunched(7)
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7, app: "Brave")], completePIDs: [7])
        discovery.enumerateAndPlace()
        clock += 0.5
        discovery.appActivated(7)

        XCTAssertEqual(manager.currentWorkspace().name, "Code")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testRouterForwardsLaunchAndActivation() {
        rule(.whenActive)
        let router = WindowEventRouter(
            context: world.routerContext(now: { [unowned self] in clock }), discovery: discovery, scheduler: scheduler
        )
        world.regular = [7]
        router.rebuild()
        arrive()

        clock += 0.4
        world.port!.deliver(SystemWindowEvent(kind: .appActivated, pid: 7, label: "App"))
        scheduler.runPending()

        XCTAssertEqual(manager.currentWorkspace().name, "Web")

        // A launch recorded by the router makes the next arrival follow.
        world.session.manager.switchTo(1)
        world.regular.insert(8)
        world.running.insert(8)
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [8])
        world.port!.deliver(SystemWindowEvent(kind: .appLaunched, pid: 8, label: "App"))
        scheduler.runPending()
        clock += 1
        arrive(pid: 8)
        XCTAssertEqual(manager.currentWorkspace().name, "Web")
    }
}
