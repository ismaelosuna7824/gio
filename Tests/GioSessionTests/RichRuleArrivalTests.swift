@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// WR-03..WR-05 in the session: an arrival honours the rule's column width,
/// maximized state, display and focus opinion; an untitled arrival is
/// re-checked once when its title appears within a second. Fake world,
/// virtual clock; titles never reach the log.
final class RichRuleArrivalTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var router: WindowEventRouter!

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        let scheduler = scheduler!
        var context = world.discoveryContext()
        context.now = { scheduler.now }
        discovery = DiscoveryService(context: context, scheduler: scheduler)
        router = WindowEventRouter(
            context: world.routerContext(now: { scheduler.now }), discovery: discovery, scheduler: scheduler
        )
        world.displaySnapshots = [DisplaySnapshot(id: DisplayID(1), frame: EventWorld.screen, visibleFrame: EventWorld.screen)]
        discovery.syncDisplays()
        world.regular = [7, 8]
        world.running = [7, 8]
        router.rebuild()
    }

    private var manager: WorkspaceManager { world.session.manager }

    private func record(pid: pid_t) -> ManagedWindow? {
        world.registered.first { $0.pid == pid }
    }

    private func column(pid: pid_t) -> Column? {
        manager.allWorkspaces.flatMap(\.columns).first { $0.windows.contains { $0.pid == pid } }
    }

    private func workspace(pid: pid_t) -> WorkspaceID? {
        manager.allWorkspaces.first { $0.columns.contains { $0.windows.contains { $0.pid == pid } } }?.id
    }

    @discardableResult
    private func arrive(_ window: DiscoveredSystemWindow) -> DiscoveredSystemWindow {
        world.classify[window.window.pid] = [window]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: window.window.pid)
        return window
    }

    private func titleChanges(_ window: DiscoveredSystemWindow, to title: String) {
        world.titles = [window.window.pid: title]
        world.port!.deliver(SystemWindowEvent(
            kind: .window(.titleChanged), pid: window.window.pid, label: "App", element: window.element
        ))
        scheduler.runPending()
    }

    // MARK: Arrival

    func testUnfocusedArrivalKeepsTheStripFocus() {
        world.session.config.rules = [WindowRule(app: "Mail", openFocused: false)]
        arrive(discovered(pid: 7, app: "Code"))
        arrive(discovered(pid: 8, app: "Mail"))
        XCTAssertEqual(manager.currentWorkspace().columns.count, 2)
        XCTAssertEqual(manager.currentWorkspace().focusedWindow?.pid, 7)
    }

    func testUnfocusedArrivalNeverFollows() {
        world.session.config.workspaces = [WorkspaceDefinition(name: "Chat")]
        discovery.syncDisplays()
        world.session.manager.switchTo(2)
        world.session.config.rules = [
            WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .always, openFocused: false),
        ]
        world.frontmost = 8
        let before = manager.currentID
        arrive(discovered(pid: 8, app: "Mail"))
        XCTAssertEqual(workspace(pid: 8), manager.namedWorkspaceID("Chat"))
        XCTAssertEqual(manager.currentID, before)
        XCTAssertTrue(world.follows.isEmpty)
    }

    func testRuleWidthAndMaximizedShapeTheColumn() {
        world.session.config.rules = [
            WindowRule(app: "Code", columnWidth: .points(900)),
            WindowRule(app: "Mail", columnWidth: .proportion(0.33333), openMaximized: true),
        ]
        arrive(discovered(pid: 7, app: "Code"))
        arrive(discovered(pid: 8, app: "Mail"))
        XCTAssertEqual(column(pid: 7)?.widthSpec, .points(900))
        XCTAssertEqual(column(pid: 8)?.widthSpec, .proportion(1))
        XCTAssertEqual(column(pid: 8)?.savedWidthSpec, .proportion(0.33333))
    }

    func testWidthLimitsAreKeptOnTheWindow() {
        world.session.config.rules = [WindowRule(app: "Code", minWidth: 500, maxWidth: 1100)]
        arrive(discovered(pid: 7, app: "Code"))
        XCTAssertEqual(record(pid: 7)?.widthLimits, ColumnWidthLimits(min: 500, max: 1100))
    }

    func testOpenOnDisplayLandsOnThatDisplay() {
        world.displaySnapshots = [
            DisplaySnapshot(id: DisplayID(1), frame: EventWorld.screen, visibleFrame: EventWorld.screen),
            DisplaySnapshot(
                id: DisplayID(2), frame: CGRect(x: 1800, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 1800, y: 0, width: 1000, height: 780)
            ),
        ]
        discovery.syncDisplays()
        world.session.config.rules = [WindowRule(app: "Mail", openOnDisplay: 2)]
        arrive(discovered(pid: 8, app: "Mail"))
        XCTAssertEqual(manager.location(of: workspace(pid: 8)!)?.display, DisplayID(2))
        XCTAssertEqual(manager.focusedDisplay, DisplayID(1))
    }

    // MARK: Title re-check

    private let meetRules = [
        WindowRule(app: "Chrome", title: TitlePattern("meet"), mode: .floating, columnWidth: .points(700)),
    ]

    func testUntitledArrivalIsRecheckedWhenItsTitleArrives() {
        world.session.config.rules = meetRules
        let window = arrive(discovered(pid: 7, title: "", app: "Chrome"))
        XCTAssertEqual(record(pid: 7)?.mode, .tiled, "no title, no title match")
        let reflows = world.reflows
        scheduler.advance(by: 0.4)
        titleChanges(window, to: "Google Meet secret")
        XCTAssertEqual(record(pid: 7)?.mode, .floating)
        XCTAssertEqual(record(pid: 7)?.floatReason, .rule)
        XCTAssertEqual(column(pid: 7)?.widthSpec, .points(700))
        XCTAssertGreaterThan(world.reflows, reflows)
        XCTAssertTrue(world.follows.isEmpty)
        XCTAssertTrue(world.focusRequests.isEmpty, "a re-check never focuses")
        XCTAssertTrue(world.logs.contains { $0.1.hasPrefix("window rule recheck id=7:") })
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret") || $0.1.contains("Meet") })
    }

    func testRecheckExpiresAfterOneSecond() {
        world.session.config.rules = meetRules
        let window = arrive(discovered(pid: 7, title: "", app: "Chrome"))
        scheduler.advance(by: 1.5)
        titleChanges(window, to: "Google Meet")
        XCTAssertEqual(record(pid: 7)?.mode, .tiled)
    }

    func testOnlyTheFirstTitleIsRechecked() {
        world.session.config.rules = meetRules
        let window = arrive(discovered(pid: 7, title: "", app: "Chrome"))
        titleChanges(window, to: "New Tab")
        titleChanges(window, to: "Google Meet")
        XCTAssertEqual(record(pid: 7)?.mode, .tiled)
    }

    func testTitledArrivalIsNeverRechecked() {
        world.session.config.rules = meetRules
        let window = arrive(discovered(pid: 7, title: "Inbox", app: "Chrome"))
        titleChanges(window, to: "Google Meet")
        XCTAssertEqual(record(pid: 7)?.mode, .tiled)
    }
}
