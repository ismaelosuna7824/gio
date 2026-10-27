@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// WC-11: macOS native window tabs through the real discovery, event router
/// and focus coordinator (fakes for AX). Each tab is its own AX window at the
/// group's frame and a fresh window list shows only the front tab, so a tab
/// group must hold one slot: Cmd+T adds no column, a tab switch keeps the
/// slot, and a background tab is never laid out (the reconciler writes only
/// laid-out windows).
final class NativeTabTests: XCTestCase {
    /// What the AX reads return: the app's fresh window list and each
    /// window's current (Cocoa) frame.
    private final class AXFacts: @unchecked Sendable {
        var listed: [pid_t: [AXUIElement]] = [:]
        var frames: [WindowID: CGRect] = [:]
    }

    /// AX (top-left) frame of the Terminal tab group, and the same in Cocoa.
    private static let groupAX = CGRect(x: 0, y: 69, width: 800, height: 600)
    private static let group = CGRect(x: 0, y: 500, width: 800, height: 600)

    private var world: EventWorld!
    private var facts: AXFacts!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var router: WindowEventRouter!
    private var focus: FocusCoordinator!
    /// Startup: the Terminal window (pid 7) and an editor window (pid 8).
    private var terminal: DiscoveredSystemWindow!
    private var editor: DiscoveredSystemWindow!
    private var terminalID: WindowID!
    private var editorID: WindowID!

    override func setUp() {
        world = EventWorld()
        facts = AXFacts()
        scheduler = ManualScheduler()
        let world = world!
        let facts = facts!
        let scheduler = scheduler!
        var discoveryContext = world.discoveryContext()
        discoveryContext.listedWindows = { facts.listed[$0] }
        discoveryContext.windowFrame = { facts.frames[$0] }
        discovery = DiscoveryService(context: discoveryContext, scheduler: scheduler)
        let discovery = discovery!
        var routerContext = world.routerContext(now: { scheduler.now })
        routerContext.frame = { facts.frames[$0] }
        routerContext.requestFocusAdoption = { [unowned self] source, pid, element in
            focus.requestAdoption(source, pid: pid, element: element)
        }
        router = WindowEventRouter(context: routerContext, discovery: discovery, scheduler: scheduler)
        focus = FocusCoordinator(
            context: .init(
                isShuttingDown: { false }, isMouseDown: { false },
                mouseLocation: { CGPoint(x: 5000, y: 5000) }, frontmostPID: { world.frontmost },
                ownPID: EventWorld.ownPID, windowAreas: { [EventWorld.screen] },
                currentWorkspace: { world.session.manager.currentWorkspace() },
                updateWorkspace: { world.session.manager.update($0) },
                isMinimized: { world.session.registry.find($0)?.isMinimized == true },
                knownWindow: { element, _ in world.known(element) },
                focusedWindowElement: { _ in nil }, frame: { facts.frames[$0] },
                registerAppeared: { discovery.registerAppeared($0, pid: $1) },
                pendingScroll: { nil }, isVisibleInViewport: { _ in true },
                topWindowOwnerPID: { _ in nil }, warpCursor: { _ in }, mouseFollowsFocus: { false },
                centerMode: { .never }, publishFocusRing: {}, reflowAll: { world.reflows += 1 },
                workspaceFocusPlan: { planFocusWindow($0, in: world.session.manager) },
                showWorkspace: { workspace, _ in _ = world.session.manager.focus(workspace) },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now },
                bringTabToFront: { discovery.bringTabToFront($0) }
            ),
            scheduler: scheduler
        )
        world.displaySnapshots = [
            DisplaySnapshot(id: DisplayID(1), frame: EventWorld.screen, visibleFrame: EventWorld.screen),
        ]
        discovery.syncDisplays()
        world.regular = [7, 8]
        world.running = [7, 8]
        world.frontmost = 7
        router.rebuild()
        terminal = discovered(pid: 7, frame: Self.groupAX, app: "Terminal")
        editor = discovered(pid: 8, frame: CGRect(x: 900, y: 69, width: 800, height: 600))
        world.scan = SystemWindowDiscoveryResult(windows: [terminal, editor], completePIDs: [7, 8])
        discovery.enumerateAndPlace()
        terminalID = world.known(terminal.element)
        editorID = world.known(editor.element)
        facts.frames[terminalID] = Self.group
        facts.listed[7] = [terminal.element]
        world.reflows = 0
    }

    private func send(_ kind: WindowEventKind, element: AXUIElement, pid: pid_t = 7) {
        world.port!.deliver(SystemWindowEvent(kind: .window(kind), pid: pid, label: "Terminal", element: element))
        scheduler.runPending()
    }

    private var columns: [[WindowID]] {
        world.session.manager.currentWorkspace().columns.map(\.windows)
    }

    /// Every frame the reconciler would be handed for the current workspace.
    private func laidOut() throws -> [WindowID: CGRect] {
        let modes = Dictionary(uniqueKeysWithValues: world.registered.map { ($0.id, $0.mode) })
        let workspace = tilingWorkspace(from: world.session.manager.currentWorkspace(), modes: modes)
        return try ScrollableLayoutEngine().calculate(workspace: workspace, viewport: EventWorld.screen).frames
    }

    private func logged(_ line: String) -> Bool {
        world.logs.contains { $0.1 == line }
    }

    private func label(_ id: WindowID) -> String {
        "\(id.pid):\(id.elementID)"
    }

    /// Cmd+T: macOS creates a tab at the group's frame and lists only it.
    @discardableResult
    private func pressCommandT() throws -> (DiscoveredSystemWindow, WindowID) {
        let tab = discovered(pid: 7, frame: Self.groupAX, app: "Terminal")
        facts.listed[7] = [tab.element]
        world.classify[7] = [tab]
        send(.windowCreated, element: tab.element)
        let id = try XCTUnwrap(world.known(tab.element))
        facts.frames[id] = Self.group
        return (tab, id)
    }

    // MARK: Joining

    func testCommandTJoinsTheWindowsSlotInsteadOfAddingAColumn() throws {
        let slot = try XCTUnwrap(try laidOut()[terminalID])

        let (_, tab) = try pressCommandT()

        XCTAssertEqual(columns, [[tab], [editorID]], "the new tab holds the window's slot")
        XCTAssertNotNil(world.session.registry.find(terminalID), "the background tab stays registered")
        XCTAssertTrue(discovery.isBackgroundTab(terminalID))
        let frames = try laidOut()
        XCTAssertEqual(frames[tab], slot)
        XCTAssertNil(frames[terminalID], "the background tab is never laid out, so never written")
        XCTAssertEqual(world.session.manager.currentWorkspace().focusedWindow, tab)
        XCTAssertFalse(world.opened.contains(tab), "no new tile enters")
        XCTAssertTrue(logged("tab joined id=\(label(tab)) group=1 front=\(label(tab))"))
    }

    func testTwoListedWindowsOfOneAppAtTheSameFrameStaySeparate() throws {
        let second = discovered(pid: 7, frame: Self.groupAX, app: "Terminal")
        facts.listed[7] = [terminal.element, second.element]
        world.classify[7] = [second]

        send(.windowCreated, element: second.element)

        let id = try XCTUnwrap(world.known(second.element))
        XCTAssertEqual(columns, [[terminalID], [editorID], [id]])
        XCTAssertFalse(discovery.isBackgroundTab(terminalID))
    }

    func testATabThatExistedAtStartupJoinsWhenItIsFirstFocused() throws {
        // The startup scan listed only the front tab; clicking the other
        // tab focuses a window Gio has never seen.
        let hidden = discovered(pid: 7, frame: Self.groupAX, app: "Terminal")
        facts.listed[7] = [hidden.element]
        world.classify[7] = [hidden]

        send(.focusedWindowChanged, element: hidden.element)

        let id = try XCTUnwrap(world.known(hidden.element))
        XCTAssertEqual(columns, [[id], [editorID]])
        XCTAssertEqual(world.session.manager.currentWorkspace().focusedWindow, id)
        XCTAssertTrue(discovery.isBackgroundTab(terminalID))
    }

    // MARK: Switching

    func testATabSwitchKeepsOneSlotAndNeverLaysOutTheBackgroundTab() throws {
        let (_, tab) = try pressCommandT()
        let slot = try XCTUnwrap(try laidOut()[tab])
        world.reflows = 0
        world.trustInvalidated = []

        facts.listed[7] = [terminal.element]
        send(.focusedWindowChanged, element: terminal.element)

        XCTAssertEqual(columns, [[terminalID], [editorID]])
        let frames = try laidOut()
        XCTAssertEqual(frames[terminalID], slot, "the shown tab gets the slot's frame")
        XCTAssertNil(frames[tab], "the tab that went behind is never written")
        XCTAssertEqual(world.session.manager.currentWorkspace().focusedWindow, terminalID)
        XCTAssertTrue(discovery.isBackgroundTab(tab))
        XCTAssertGreaterThan(world.reflows, 0, "the slot's frame is written to the new front")
        XCTAssertTrue(world.trustInvalidated.contains(terminalID))
        XCTAssertTrue(logged("tab front id=\(label(terminalID))"))
    }

    func testABackgroundTabFollowingItsGroupRaisesNoReflow() throws {
        let (_, id) = try pressCommandT()
        world.scheduledReflows = []
        world.trustInvalidated = []
        let moved = Self.group.offsetBy(dx: 40, dy: 0)
        facts.frames[id] = moved
        facts.frames[terminalID] = moved

        send(.moved, element: terminal.element)

        XCTAssertEqual(world.scheduledReflows, [])
        XCTAssertEqual(world.trustInvalidated, [])
        XCTAssertEqual(columns, [[id], [editorID]])
    }

    func testARescanThatListsOnlyTheFrontTabKeepsTheBackgroundTab() throws {
        let (tab, id) = try pressCommandT()
        world.scan = SystemWindowDiscoveryResult(windows: [tab, editor], completePIDs: [7, 8])

        discovery.enumerateAndPlace()

        XCTAssertNotNil(world.session.registry.find(terminalID), "absent from the fresh list is not closed")
        XCTAssertEqual(columns, [[id], [editorID]])
    }

    func testARescanThatListsABackgroundTabMakesItTheFront() throws {
        let (_, id) = try pressCommandT()
        world.scan = SystemWindowDiscoveryResult(windows: [terminal, editor], completePIDs: [7, 8])

        discovery.enumerateAndPlace()

        XCTAssertEqual(columns, [[terminalID], [editorID]], "a missed tab switch heals")
        XCTAssertTrue(discovery.isBackgroundTab(id))
        XCTAssertNotNil(world.session.registry.find(id))
    }

    func testABackgroundTabDeminimizedOpensNoColumn() throws {
        let (_, id) = try pressCommandT()

        send(.deminiaturized, element: terminal.element)

        XCTAssertEqual(columns, [[id], [editorID]])
    }

    /// SM-31: a window the reconciler reports vanished asks for a complete
    /// scan of its pid; that scan lists only the front tab.
    func testAVanishedScanNeverPurgesTheBackgroundTabs() throws {
        let (tab, id) = try pressCommandT()
        world.scan = SystemWindowDiscoveryResult(windows: [tab], completePIDs: [7])

        discovery.noteSettled(vanished: [id], alive: [])
        scheduler.runPending()

        XCTAssertNotNil(
            world.session.registry.find(terminalID), "only a destroyed event, a dead pid or leaving the group"
        )
        XCTAssertTrue(discovery.isBackgroundTab(terminalID))
        XCTAssertEqual(columns, [[id], [editorID]])
    }

    func testAVanishedScanThatListsTheBackgroundTabHealsTheSwitchAndReflows() throws {
        let (_, id) = try pressCommandT()
        world.scan = SystemWindowDiscoveryResult(windows: [terminal], completePIDs: [7])
        world.reflows = 0

        discovery.noteSettled(vanished: [id], alive: [])
        scheduler.runPending()

        XCTAssertEqual(columns, [[terminalID], [editorID]])
        XCTAssertNotNil(world.session.registry.find(id), "the unlisted tab of a listed group is not gone")
        XCTAssertEqual(world.reflows, 1, "the slot's frame goes to the tab macOS shows")
    }

    // MARK: Leaving

    func testClosingTheFrontTabPromotesTheOtherTabIntoTheSlot() throws {
        let (tab, id) = try pressCommandT()
        let slot = try XCTUnwrap(try laidOut()[id])

        send(.destroyed, element: tab.element)

        XCTAssertEqual(columns, [[terminalID], [editorID]])
        XCTAssertEqual(try laidOut()[terminalID], slot)
        XCTAssertFalse(discovery.isBackgroundTab(terminalID))
        XCTAssertNil(world.session.registry.find(id))
        XCTAssertTrue(logged("tab left id=\(label(id)) reason=closed"))
        XCTAssertTrue(logged("tab front id=\(label(terminalID))"))
    }

    func testATabDraggedOutBecomesItsOwnColumn() throws {
        let (tab, id) = try pressCommandT()
        facts.frames[id] = Self.group.offsetBy(dx: 300, dy: -120)
        facts.listed[7] = [terminal.element, tab.element]

        send(.moved, element: tab.element)

        XCTAssertEqual(columns, [[terminalID], [editorID], [id]], "the window left behind keeps the slot")
        XCTAssertFalse(discovery.isBackgroundTab(terminalID))
        XCTAssertFalse(discovery.isBackgroundTab(id))
        XCTAssertTrue(logged("tab left id=\(label(id)) reason=draggedOut"))
    }

    func testTheWholeGroupDraggedIsAnOrdinaryMove() throws {
        let (tab, id) = try pressCommandT()
        world.scheduledReflows = []
        // macOS has not moved the background tab yet; only the front is listed.
        facts.frames[id] = Self.group.offsetBy(dx: 300, dy: 0)

        send(.moved, element: tab.element)

        XCTAssertEqual(columns, [[id], [editorID]])
        XCTAssertTrue(discovery.isBackgroundTab(terminalID))
        XCTAssertEqual(world.scheduledReflows, [false], "the slot snaps back as for any window")
    }

    /// PA-18c: a drag reads an ordinary window once, but a tab every time:
    /// the group dragged as a whole may turn into a tab dragged out.
    func testATabDraggedOutMidDragIsStillSeen() throws {
        let (tab, id) = try pressCommandT()
        world.mouseDown = true
        facts.frames[id] = Self.group.offsetBy(dx: 300, dy: 0)
        send(.moved, element: tab.element)
        XCTAssertEqual(columns, [[id], [editorID]], "the whole group moves first")

        facts.frames[id] = Self.group.offsetBy(dx: 300, dy: -120)
        facts.listed[7] = [terminal.element, tab.element]
        send(.moved, element: tab.element)

        XCTAssertTrue(logged("tab left id=\(label(id)) reason=draggedOut"))
        XCTAssertEqual(columns, [[terminalID], [editorID], [id]])
    }
}
