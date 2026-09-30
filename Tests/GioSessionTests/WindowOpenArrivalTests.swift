@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// PF-02: how an arrival reaches the next pass. Only a window landing on the
/// shown workspace enters from below; one routed to a hidden workspace is
/// just placed, and one that takes the user there rides the workspace switch
/// (one pass, no separate entry). Unreadable frames retry sooner; every
/// registration hands its timing to the host.
final class WindowOpenArrivalTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var timings: [WindowOpenTiming] = []
    private var logs: [String] = []

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        var context = world.discoveryContext()
        context.now = { [unowned self] in scheduler.now }
        context.windowRegistered = { [unowned self] in timings.append($0) }
        context.log = { [unowned self] _, line in logs.append(line) }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        world.session.config.workspaces = [WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Web")]
        discovery.syncDisplays()
        world.session.manager.switchTo(1)
    }

    private func arrive(_ window: DiscoveredSystemWindow) {
        world.classify[window.window.pid] = [window]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: window.window.pid)
    }

    func testArrivalOnTheShownWorkspaceEnters() {
        arrive(discovered(pid: 7, app: "Code"))
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertEqual(world.reflows, 1)
    }

    func testArrivalRoutedToAHiddenWorkspaceHasNoEntry() {
        world.session.config.rules = [WindowRule(app: "Firefox", openOnWorkspace: "Web", follow: .never)]
        arrive(discovered(pid: 7, app: "Firefox"))
        XCTAssertTrue(world.opened.isEmpty, "hidden: parked by the pass, nothing to animate in")
        XCTAssertEqual(world.reflows, 1)
    }

    func testFollowedArrivalStartsTheSwitchInTheRegistrationPass() {
        world.session.config.rules = [WindowRule(app: "Firefox", openOnWorkspace: "Web", follow: .always)]
        arrive(discovered(pid: 7, app: "Firefox"))
        XCTAssertEqual(world.session.manager.currentWorkspace().name, "Web")
        XCTAssertEqual(world.follows.count, 1)
        XCTAssertTrue(world.opened.isEmpty, "no entry: the switch brings it in")
        XCTAssertEqual(world.reflows, 1, "one combined pass, right at registration")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testRegistrationReportsItsTiming() throws {
        world.session.config.rules = [WindowRule(app: "Firefox", openOnWorkspace: "Web", follow: .always)]
        let element = AXUIElementCreateApplication(4242)
        world.running = [7]
        world.classify[7] = [nil, discovered(pid: 7, app: "Firefox")]
        discovery.registerAppeared(element, pid: 7)
        scheduler.advance(by: 0.1)

        let timing = try XCTUnwrap(timings.first)
        XCTAssertEqual(timing.app, "Firefox")
        XCTAssertEqual(timing.createdAt, 0, accuracy: 1e-9, "the created event, not the retry")
        XCTAssertEqual(timing.registeredAt, 0.1, accuracy: 1e-9)
        XCTAssertEqual(timing.retries, 1)
        XCTAssertEqual(timing.workspace, "Web")
        XCTAssertTrue(timing.follow)
        XCTAssertTrue(logs.contains { $0.hasPrefix("window register retry pid=7 attempt=1") }, "\(logs)")
    }

    func testUnreadableFrameRetriesOnTheFastSchedule() {
        var context = world.discoveryContext()
        var attempts: [SingleWindowDiscovery] = [.frameUnreadable, .found(discovered(pid: 7))]
        context.discoverAttempt = { _, _ in attempts.removeFirst() }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        world.running = [7]

        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)
        XCTAssertTrue(world.registered.isEmpty)
        scheduler.advance(by: 0.03)

        XCTAssertEqual(world.registered.count, 1, "30 ms, not 100 ms")
    }
}
