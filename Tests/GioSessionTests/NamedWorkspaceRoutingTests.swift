@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// NW-02: arriving windows go to their rule's named workspace (bundle id
/// first, then app name), and the follow policy decides whether the user is
/// taken there. Fake frontmost pid; no desktop is touched.
final class NamedWorkspaceRoutingTests: XCTestCase {
    private var world: EventWorld!
    private var discovery: DiscoveryService!

    override func setUp() {
        world = EventWorld()
        discovery = DiscoveryService(context: world.discoveryContext(), scheduler: ManualScheduler())
        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(1), frame: EventWorld.screen,
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
        )]
        world.session.config.workspaces = [WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Chat")]
        discovery.syncDisplays()
        // Start on a dynamic workspace below the named ones.
        world.session.manager.switchTo(3)
    }

    private var manager: WorkspaceManager { world.session.manager }

    private func windows(in name: String) -> [WindowID] {
        manager.workspace(id: manager.namedWorkspaceID(name)!)!.columns.flatMap(\.windows)
    }

    private func arrive(_ window: DiscoveredSystemWindow) {
        world.classify[window.window.pid] = [window]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: window.window.pid)
    }

    func testBundleIDRuleRoutesToTheNamedWorkspace() {
        world.session.config.rules = [
            WindowRule(app: "", bundleID: "com.microsoft.VSCode", openOnWorkspace: "Code", follow: .never),
        ]
        arrive(discovered(pid: 7, app: "Code", bundleID: "com.microsoft.VSCode"))
        XCTAssertEqual(windows(in: "Code").map(\.pid), [7])
        XCTAssertEqual(world.registered.first?.bundleID, "com.microsoft.VSCode")
        XCTAssertNil(manager.currentWorkspace().name, "never: the user stays put")
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testAppNameRuleRoutesWhenNoBundleRuleMatches() {
        world.session.config.rules = [
            WindowRule(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", openOnWorkspace: "Code", follow: .never),
            WindowRule(app: "Slack", openOnWorkspace: "Chat", follow: .never),
        ]
        // Same name, different bundle: the bundle rule does not match.
        arrive(discovered(pid: 7, app: "Slack", bundleID: "com.other.slack"))
        XCTAssertEqual(windows(in: "Chat").map(\.pid), [7])
        XCTAssertEqual(windows(in: "Code"), [])
    }

    func testFollowAlwaysSwitchesAndRequestsFocus() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .always)]
        world.frontmost = 99
        arrive(discovered(pid: 7, app: "Mail"))
        XCTAssertEqual(manager.currentWorkspace().name, "Chat")
        XCTAssertEqual(manager.currentWorkspace().focusedWindow?.pid, 7)
        XCTAssertEqual(world.follows.count, 1)
    }

    func testFollowWhenActiveOnlyForTheFrontmostApp() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat")]
        world.frontmost = 99
        arrive(discovered(pid: 7, app: "Mail"))
        XCTAssertEqual(windows(in: "Chat").map(\.pid), [7], "routed silently")
        XCTAssertNil(manager.currentWorkspace().name)
        XCTAssertTrue(world.follows.isEmpty)

        world.frontmost = 8
        arrive(discovered(pid: 8, app: "Mail"))
        XCTAssertEqual(manager.currentWorkspace().name, "Chat")
        XCTAssertEqual(world.follows.count, 1)
    }

    func testMinimizedArrivalNeverFollows() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .always)]
        arrive(discovered(pid: 7, minimized: true, app: "Mail"))
        XCTAssertNil(manager.currentWorkspace().name)
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testFullScanRoutesButNeverFollows() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .always)]
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7, app: "Mail")], completePIDs: [7])
        world.running = [7]
        discovery.enumerateAndPlace()
        XCTAssertEqual(windows(in: "Chat").map(\.pid), [7])
        XCTAssertNil(manager.currentWorkspace().name)
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testLaunchedAppFollows() {
        world.session.config.rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat")]
        world.frontmost = 7
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7, app: "Mail")], completePIDs: [7])
        world.running = [7]
        discovery.appAttached(7)
        XCTAssertEqual(manager.currentWorkspace().name, "Chat")
        XCTAssertEqual(world.follows.count, 1)
    }

    func testFloatingRuleStillApplies() {
        world.session.config.rules = [
            WindowRule(app: "Calc", mode: .floating, openOnWorkspace: "Code", follow: .never),
        ]
        arrive(discovered(pid: 7, app: "Calc"))
        XCTAssertEqual(world.registered.first?.mode, .floating)
        XCTAssertEqual(world.registered.first?.floatReason, .rule)
        XCTAssertEqual(windows(in: "Code").map(\.pid), [7])
    }

    /// Live 2026-10-15: Chrome's address-bar suggestions (a fixed-size popup
    /// re-created as the user types) matched the Chrome rule, and every one
    /// took the user to "Browsers": workspace switch, keyboard focus and
    /// cursor on the other display, typing lost. A window discovery floats
    /// (popup, dialog, panel) stays where the user is and never follows.
    func testAPopupOfARoutedAppStaysWhereTheUserIsAndNeverFollows() {
        world.session.config.rules = [WindowRule(app: "Chrome", openOnWorkspace: "Chat", follow: .always)]
        world.frontmost = 7
        let before = manager.currentID
        arrive(discovered(pid: 7, app: "Chrome", floatReason: .notResizable))
        XCTAssertEqual(manager.currentID, before, "the user stays put")
        XCTAssertTrue(world.follows.isEmpty)
        XCTAssertEqual(windows(in: "Chat"), [])
        XCTAssertEqual(manager.currentWorkspace().columns.flatMap(\.windows).map(\.pid), [7])
        XCTAssertEqual(world.registered.first?.floatReason, .notResizable)
    }

    func testARealWindowOfTheSameAppStillFollowsItsRule() {
        world.session.config.rules = [WindowRule(app: "Chrome", openOnWorkspace: "Chat", follow: .always)]
        world.frontmost = 7
        arrive(discovered(pid: 7, app: "Chrome", floatReason: .notResizable))
        arrive(discovered(pid: 7, app: "Chrome"))
        XCTAssertEqual(manager.currentWorkspace().name, "Chat")
        XCTAssertEqual(world.follows.count, 1)
    }

    func testDisplaySyncPassesTheMainDisplay() {
        world.session.config.workspaces = [
            WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Chat", display: .index(2)),
        ]
        // Display 9 sorts after 4 but sits at the origin: it is the main one.
        world.displaySnapshots = [
            DisplaySnapshot(
                id: DisplayID(4), frame: CGRect(x: 1800, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 1800, y: 0, width: 1000, height: 780)
            ),
            DisplaySnapshot(id: DisplayID(9), frame: EventWorld.screen, visibleFrame: EventWorld.screen),
        ]
        discovery.syncDisplays()
        XCTAssertEqual(manager.mainDisplay, DisplayID(9))
        XCTAssertEqual(manager.location(of: manager.namedWorkspaceID("Code")!)?.display, DisplayID(9))
        XCTAssertEqual(manager.location(of: manager.namedWorkspaceID("Chat")!)?.display, DisplayID(4))
    }
}
