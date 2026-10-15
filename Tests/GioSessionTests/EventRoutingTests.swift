@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// Records attach/detach/watch; `attachResults` scripts refusals per pid.
final class FakeEventPort: EventPort, @unchecked Sendable {
    var attachResults: [pid_t: [Bool]] = [:]
    private(set) var attachCalls: [pid_t] = []
    private(set) var detached: [pid_t] = []
    private(set) var watched: [pid_t] = []
    private(set) var stops = 0
    let deliver: @Sendable (SystemWindowEvent) -> Void

    init(deliver: @escaping @Sendable (SystemWindowEvent) -> Void) {
        self.deliver = deliver
    }

    func attach(pid: pid_t) -> Bool {
        attachCalls.append(pid)
        guard var results = attachResults[pid], !results.isEmpty else {
            return true
        }
        let result = results.removeFirst()
        attachResults[pid] = results
        return result
    }

    func detach(pid: pid_t) {
        detached.append(pid)
    }

    func watch(window element: AXUIElement, pid: pid_t) -> Bool {
        watched.append(pid)
        return true
    }

    func stop() {
        stops += 1
    }
}

/// Host state behind the discovery and router contexts. Elements are real
/// (application) AX elements used as opaque handles; nothing reads them.
final class EventWorld: @unchecked Sendable {
    static let ownPID: pid_t = 999
    static let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    var session = CommandSession()
    var handles: [(AXUIElement, WindowID)] = []
    var scan: SystemWindowDiscoveryResult?
    var scans: [pid_t?] = []
    var classify: [pid_t: [DiscoveredSystemWindow?]] = [:]
    var running: Set<pid_t> = []
    var regular: Set<pid_t> = []
    var frontmost: pid_t?
    var click: MouseClick?
    var adopted: [WindowID] = []
    var trustInvalidated: [WindowID] = []
    var reset: [WindowID] = []
    var forgotten: [WindowID] = []
    var forgottenApps: [pid_t] = []
    var opened: [WindowID] = []
    /// NW-02: follow requests (the focus before the switch).
    var follows: [WindowID?] = []
    /// NA-03: (ids, still registered when reported).
    var closing: [([WindowID], Bool)] = []
    var reflows = 0
    var scheduledReflows: [Bool] = []
    var displaySnapshots: [DisplaySnapshot] = []
    var displays = DisplayManager()
    var visibleFrames: [DisplayID: CGRect] = [:]
    var displayHeights: [CGFloat] = []
    var displayChanges = 0
    // Router.
    var tapMissing = false
    var focusRequests: [(FocusSource, pid_t)] = []
    var dimUpdates = 0
    var dragHolds = 0
    var animating: Set<pid_t> = []
    var knownLookups = 0
    var zoomBusy: Set<WindowID> = []
    var zoomForgotten: [WindowID] = []
    var suppressed: Set<WindowID> = []
    var echoes: Set<WindowID> = []
    var frameReads: [WindowID] = []
    var tileabilityInvalidated: [WindowID] = []
    var titles: [pid_t: String] = [:]
    var titleReads = 0
    var console: [String] = []
    var logs: [(LogLevel, String)] = []
    var port: FakeEventPort?
    var portScript: [pid_t: [Bool]] = [:]
    /// FI-10: when Gio last wrote each window (`WriteEchoGate.lastWrite`).
    var lastWrites: [WindowID: TimeInterval] = [:]
    var mouseDown = false
    /// FI-11: the frame Gio last wrote (`WriteEchoGate.writtenFrame`), whether
    /// the host learns a late clamp, and the (window, written, observed) asked.
    var writtenFrames: [WindowID: CGRect] = [:]
    var learnsLateClamp = false
    var lateClampAsks: [(WindowID, CGRect, CGRect)] = []

    func known(_ element: AXUIElement) -> WindowID? {
        handles.first { CFEqual($0.0, element) }?.1
    }

    var registered: [ManagedWindow] {
        session.registry.managedWindows()
    }

    func discoveryContext() -> DiscoveryService.Context {
        .init(
            ownPID: Self.ownPID,
            registry: { self.session.registry },
            manager: { self.session.manager },
            updateManager: { body in body(&self.session.manager) },
            rules: { self.session.config.rules },
            discoverAll: { pid in
                self.scans.append(pid)
                return self.scan
            },
            discoverOne: { _, pid in
                guard var queue = self.classify[pid], !queue.isEmpty else {
                    return nil
                }
                let next = queue.removeFirst()
                self.classify[pid] = queue
                return next
            },
            knownWindow: { element, _ in self.known(element) },
            registerHandles: { id, candidate in self.handles.append((candidate.element, id)) },
            watchWindow: { _, pid in _ = self.port?.watch(window: AXUIElementCreateApplication(pid), pid: pid) },
            displayHeight: { Self.screen.height },
            isRunning: { self.running.contains($0) },
            frontmostPID: { self.frontmost },
            currentClick: { self.click },
            adoptFocus: { id, _ in self.adopted.append(id) },
            invalidateTrust: { self.trustInvalidated.append($0) },
            resetWindowState: { self.reset.append($0) },
            forgetWindow: { self.forgotten.append($0) },
            forgetApp: { self.forgottenApps.append($0) },
            reflowAll: { self.reflows += 1 },
            displaySnapshots: { self.displaySnapshots },
            knownDisplayIDs: { self.displays.allDisplays().map(\.id) },
            connectDisplay: { display, workspace in
                self.visibleFrames[display.id] = display.visibleFrame
                self.displays.connect(display.id, frame: display.frame, workspace: workspace)
            },
            disconnectDisplay: { id in
                self.displays.disconnect(id)
                self.visibleFrames.removeValue(forKey: id)
            },
            displayFrames: { self.visibleFrames },
            updateDisplayHeight: { self.displayHeights.append($0) },
            displaysChanged: { self.displayChanges += 1 },
            windowOpened: { self.opened.append($0) },
            windowsClosing: { ids in
                self.closing.append((ids, ids.allSatisfy { self.session.registry.find($0) != nil }))
            },
            followArrival: { self.follows.append($0) },
            log: { self.logs.append(($0, $1)) }
        )
    }

    func routerContext(now: @escaping () -> TimeInterval) -> WindowEventRouter.Context {
        .init(
            makePort: { deliver in
                let port = FakeEventPort(deliver: deliver)
                port.attachResults = self.portScript
                self.port = port
                return port
            },
            ownPID: Self.ownPID,
            runningRegularPIDs: { self.regular },
            isRegularApplication: { self.regular.contains($0) },
            isTapMissing: { self.tapMissing },
            scheduleReflow: { self.scheduledReflows.append($0) },
            reflowAll: { self.reflows += 1 },
            requestFocusAdoption: { source, pid, _ in self.focusRequests.append((source, pid)) },
            updateDim: { self.dimUpdates += 1 },
            holdDimForDrag: { self.dragHolds += 1 },
            animatingPids: { self.animating },
            knownWindow: { element, _ in
                self.knownLookups += 1
                return self.known(element)
            },
            isZoomBusy: { self.zoomBusy.contains($0) },
            forgetZoom: { self.zoomForgotten.append($0) },
            isEchoSuppressed: { id, _ in self.suppressed.contains(id) },
            frame: { id in
                self.frameReads.append(id)
                return CGRect(x: 0, y: 0, width: 100, height: 100)
            },
            isEcho: { id, _, _ in self.echoes.contains(id) },
            invalidateTrust: { self.trustInvalidated.append($0) },
            invalidateTileability: { self.tileabilityInvalidated.append($0) },
            title: { _ in
                self.titleReads += 1
                return self.titles.values.first
            },
            registry: { self.session.registry },
            console: { self.console.append($0) },
            log: { self.logs.append(($0, $1)) },
            now: now,
            lastWrite: { self.lastWrites[$0] },
            isMouseDown: { self.mouseDown },
            writtenFrame: { self.writtenFrames[$0] },
            learnLateClamp: { id, written, observed in
                self.lateClampAsks.append((id, written, observed))
                return self.learnsLateClamp
            }
        )
    }
}

/// Distinct opaque elements for fake windows.
nonisolated(unsafe) private var nextFakeElement: pid_t = 50_000

/// A discovered window of `pid` with a fresh opaque element.
func discovered(
    pid: pid_t, title: String = "secret title", frame: CGRect = CGRect(x: 0, y: 69, width: 800, height: 600),
    focused: Bool = false, minimized: Bool = false, app: String = "Code", floatReason: FloatReason? = nil,
    bundleID: String? = nil
) -> DiscoveredSystemWindow {
    DiscoveredSystemWindow(
        window: SystemWindow(
            index: 0, pid: pid, appName: app, title: title, frame: frame,
            isFocused: focused, isMinimized: minimized, isFullscreen: false, bundleID: bundleID
        ),
        element: {
            nextFakeElement += 1
            return AXUIElementCreateApplication(nextFakeElement)
        }(),
        appElement: AXUIElementCreateApplication(pid),
        floatReason: floatReason
    )
}

final class DiscoveryServiceTests: XCTestCase {
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

    private var currentColumns: [[WindowID]] {
        world.session.manager.currentWorkspace().columns.map(\.windows)
    }

    // MARK: Own pid, every entry point

    func testOwnPidIsNeverRegisteredByTheFullScan() {
        let other = discovered(pid: 7)
        world.scan = SystemWindowDiscoveryResult(
            windows: [discovered(pid: EventWorld.ownPID), other],
            floating: [discovered(pid: EventWorld.ownPID)], completePIDs: [7, EventWorld.ownPID]
        )
        world.running = [7]

        discovery.enumerateAndPlace()

        XCTAssertEqual(world.registered.map(\.pid), [7])
        XCTAssertFalse(world.handles.contains { $0.1.pid == EventWorld.ownPID })
    }

    func testOwnPidIsNeverRegisteredWhenItAppears() {
        world.classify[EventWorld.ownPID] = [discovered(pid: EventWorld.ownPID)]

        discovery.registerAppeared(AXUIElementCreateApplication(1), pid: EventWorld.ownPID)
        scheduler.advance(by: 5)

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertTrue(world.handles.isEmpty)
    }

    func testOwnPidIsNeverRegisteredByALaunchScan() {
        world.scan = SystemWindowDiscoveryResult(
            windows: [discovered(pid: EventWorld.ownPID)], completePIDs: [EventWorld.ownPID]
        )

        discovery.appAttached(EventWorld.ownPID)

        XCTAssertEqual(world.scans, [EventWorld.ownPID])
        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.reflows, 1)
    }

    // MARK: Scan

    func testScanRegistersArrivalsInNewFocusedColumnsAndKeepsKnownIdentity() {
        let first = discovered(pid: 7)
        world.scan = SystemWindowDiscoveryResult(windows: [first], completePIDs: [7])
        world.running = [7]
        discovery.enumerateAndPlace()
        let id = try? XCTUnwrap(world.registered.first?.id)

        XCTAssertEqual(currentColumns, [[id!]])
        XCTAssertEqual(world.session.manager.currentWorkspace().focusedWindow, id)
        XCTAssertEqual(world.reset, [id!])
        // Cocoa flip: AX y=69 with height 600 on a 1169 screen -> y=500.
        XCTAssertEqual(world.registered.first?.frame.minY, 500)

        discovery.enumerateAndPlace()
        XCTAssertEqual(world.registered.count, 1, "retained handles keep their id")
    }

    func testRescanAdoptsTheFrontmostFocusUnlessAClickIsInFlight() {
        let window = discovered(pid: 7, focused: true)
        world.scan = SystemWindowDiscoveryResult(windows: [window], completePIDs: [7])
        world.running = [7]
        world.frontmost = 7
        discovery.enumerateAndPlace()
        XCTAssertTrue(world.adopted.isEmpty, "new windows are focused by registration, not adoption")

        world.click = MouseClick(location: .zero, time: 0)
        discovery.enumerateAndPlace()
        XCTAssertTrue(world.adopted.isEmpty)

        world.click = nil
        discovery.enumerateAndPlace()
        XCTAssertEqual(world.adopted, world.registered.map(\.id))
    }

    func testMissedMinimizeHealsOnRescan() {
        let window = discovered(pid: 7)
        world.scan = SystemWindowDiscoveryResult(windows: [window], completePIDs: [7])
        world.running = [7]
        discovery.enumerateAndPlace()
        let id = world.registered[0].id

        world.scan = SystemWindowDiscoveryResult(
            windows: [DiscoveredSystemWindow(
                window: SystemWindow(
                    index: 0, pid: 7, appName: "Code", title: nil, frame: window.window.frame,
                    isFocused: false, isMinimized: true, isFullscreen: false
                ),
                element: window.element, appElement: window.appElement
            )],
            completePIDs: [7]
        )
        discovery.enumerateAndPlace()

        XCTAssertEqual(world.registered.first?.isMinimized, true)
        XCTAssertTrue(world.trustInvalidated.contains(id))
    }

    func testVanishedWindowsArePurgedOnlyForCompletelyReadPids() {
        let a = discovered(pid: 7)
        let b = discovered(pid: 8)
        world.scan = SystemWindowDiscoveryResult(windows: [a, b], completePIDs: [7, 8])
        world.running = [7, 8]
        discovery.enumerateAndPlace()
        XCTAssertEqual(world.registered.count, 2)

        // Both missing, but pid 8's list was not read completely: kept.
        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [7])
        discovery.enumerateAndPlace()

        XCTAssertEqual(world.registered.map(\.pid), [8])
        XCTAssertEqual(world.forgotten.map(\.pid), [7])
        XCTAssertEqual(currentColumns.flatMap { $0 }.map(\.pid), [8])
    }

    func testDeadPidsAreReapedOnFullScansOnly() {
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 7)], completePIDs: [7])
        world.running = [7]
        discovery.enumerateAndPlace()

        world.scan = SystemWindowDiscoveryResult(windows: [], completePIDs: [])
        discovery.enumerateAndPlace(onlyPID: 9)
        XCTAssertEqual(world.registered.count, 1, "a partial scan proves nothing")
        discovery.enumerateAndPlace()
        XCTAssertEqual(world.registered.count, 1, "still running")

        world.running = []
        discovery.enumerateAndPlace()
        XCTAssertTrue(world.registered.isEmpty)
    }

    func testRulesAndAdmissionDecideTheMode() {
        world.session.config.rules = [WindowRule(app: "Finder", mode: .floating)]
        world.scan = SystemWindowDiscoveryResult(
            windows: [discovered(pid: 7, app: "Finder"), discovered(pid: 8, floatReason: .dialog)],
            completePIDs: [7, 8]
        )
        world.running = [7, 8]
        discovery.enumerateAndPlace()

        let byPid = Dictionary(uniqueKeysWithValues: world.registered.map { ($0.pid, $0) })
        XCTAssertEqual(byPid[7]?.mode, .floating)
        XCTAssertEqual(byPid[7]?.floatReason, .rule)
        XCTAssertEqual(byPid[8]?.floatReason, .dialog)
    }

    // MARK: Appeared, terminated, purge

    func testAppearedWindowIsRetriedWhileUnreadableThenRegistered() {
        world.running = [7]
        world.classify[7] = [nil, nil, discovered(pid: 7)]
        let element = AXUIElementCreateApplication(4242)

        discovery.registerAppeared(element, pid: 7)
        XCTAssertTrue(world.registered.isEmpty)
        scheduler.advance(by: 0.1)
        XCTAssertTrue(world.registered.isEmpty)
        scheduler.advance(by: 0.3)

        XCTAssertEqual(world.registered.count, 1)
        XCTAssertEqual(world.reflows, 1)
    }

    func testAppearedWindowIsHandedToTheNextPassAsOpened() {
        world.classify[7] = [discovered(pid: 7), discovered(pid: 7, minimized: true)]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)
        discovery.registerAppeared(AXUIElementCreateApplication(4243), pid: 7)

        let visible = world.registered.filter { !$0.isMinimized }.map(\.id)
        XCTAssertEqual(world.registered.count, 2)
        XCTAssertEqual(world.opened, visible, "a minimized arrival has nothing to animate")
    }

    func testAppearedWindowGivesUpAfterTheRetries() {
        world.running = [7]
        world.classify[7] = [nil, nil, nil, nil, discovered(pid: 7)]
        discovery.registerAppeared(AXUIElementCreateApplication(4242), pid: 7)
        scheduler.advance(by: 5)

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testTerminatedAppIsReapedAtOnce() {
        world.scan = SystemWindowDiscoveryResult(
            windows: [discovered(pid: 7), discovered(pid: 7), discovered(pid: 8)], completePIDs: [7, 8]
        )
        world.running = [7, 8]
        discovery.enumerateAndPlace()

        discovery.appTerminated(7)

        XCTAssertEqual(world.forgottenApps, [7])
        XCTAssertEqual(world.registered.map(\.pid), [8])
        XCTAssertEqual(world.forgotten.count, 2)
        XCTAssertEqual(world.reflows, 1)
    }

    // MARK: Displays

    func testDisplaySyncConnectsAndDisconnects() {
        XCTAssertEqual(world.displays.allDisplays().map(\.id), [DisplayID(1)])
        XCTAssertEqual(world.visibleFrames[DisplayID(1)]?.height, 1130)
        XCTAssertEqual(world.displayHeights, [1169])
        XCTAssertEqual(world.displayChanges, 1)

        world.displaySnapshots = [DisplaySnapshot(
            id: DisplayID(2), frame: CGRect(x: 1800, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1800, y: 0, width: 1512, height: 950)
        )]
        discovery.syncDisplays()

        XCTAssertEqual(world.displays.allDisplays().map(\.id), [DisplayID(2)])
        XCTAssertNil(world.visibleFrames[DisplayID(1)])
        XCTAssertEqual(world.displayChanges, 2)
    }

    // MARK: Multi-display (MM-01)

    private static let leftExternal = DisplaySnapshot(
        id: DisplayID(1), frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1415)
    )
    private static let primary = DisplaySnapshot(
        id: DisplayID(2), frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950)
    )
    private static let rightExternal = DisplaySnapshot(
        id: DisplayID(3), frame: CGRect(x: 1512, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1600, height: 975)
    )

    /// A world whose displays have not been synced yet (the startup state).
    private func freshDiscovery() -> (EventWorld, DiscoveryService) {
        let fresh = EventWorld()
        return (fresh, DiscoveryService(context: fresh.discoveryContext(), scheduler: scheduler))
    }

    func testDisplaySyncFlipsWithThePrimaryDisplayHeight() {
        // The AX flip is global: the primary display (Cocoa origin) sets it,
        // whatever display holds the key window or comes first.
        world.displaySnapshots = [Self.leftExternal, Self.primary]
        discovery.syncDisplays()
        XCTAssertEqual(world.displayHeights.last, 982)
    }

    func testDisplaySyncOrdersDisplaysByPositionAndFocusesTheMainOne() {
        let (fresh, service) = freshDiscovery()
        fresh.displaySnapshots = [Self.rightExternal, Self.primary, Self.leftExternal]
        service.syncDisplays()
        XCTAssertEqual(fresh.session.manager.displayIDs, [DisplayID(1), DisplayID(2), DisplayID(3)])
        XCTAssertEqual(fresh.session.manager.mainDisplay, DisplayID(2))
        XCTAssertEqual(fresh.session.manager.focusedDisplay, DisplayID(2))
    }

    func testStartupScanPlacesEachWindowOnTheDisplayItSitsOn() {
        let (fresh, service) = freshDiscovery()
        fresh.displaySnapshots = [Self.primary, Self.rightExternal]
        service.syncDisplays()
        // AX frames (top-left origin, flipped with the 1169 test height).
        let onPrimary = discovered(pid: 7, frame: CGRect(x: 100, y: 300, width: 800, height: 600))
        let onRight = discovered(pid: 8, frame: CGRect(x: 1700, y: 300, width: 1200, height: 600))
        let straddling = discovered(pid: 9, frame: CGRect(x: 1300, y: 300, width: 600, height: 600))
        let offscreen = discovered(pid: 10, frame: CGRect(x: 9000, y: 300, width: 600, height: 600))
        fresh.scan = SystemWindowDiscoveryResult(
            windows: [onPrimary, onRight, straddling, offscreen], completePIDs: [7, 8, 9, 10]
        )
        fresh.running = [7, 8, 9, 10]

        service.enumerateAndPlace()

        let manager = fresh.session.manager
        func pids(on display: DisplayID) -> [pid_t] {
            manager.workspace(id: manager.activeID(on: display)!)!.columns.flatMap(\.windows).map(\.pid)
        }
        // The straddling window has more of itself on the right display;
        // a window on no display stays on the focused one.
        XCTAssertEqual(pids(on: DisplayID(2)), [7, 10])
        XCTAssertEqual(pids(on: DisplayID(3)), [8, 9])
    }

    func testALiveArrivalGoesToTheFocusedDisplayWhereverItOpens() {
        world.displaySnapshots = [Self.primary, Self.rightExternal]
        discovery.syncDisplays()
        let focusedDisplay = world.session.manager.focusedDisplay
        world.running = [7]
        world.classify[7] = [discovered(pid: 7, frame: CGRect(x: 1700, y: 300, width: 1200, height: 600))]

        discovery.registerAppeared(AXUIElementCreateApplication(1), pid: 7)

        let manager = world.session.manager
        XCTAssertEqual(
            manager.workspace(id: manager.activeID(on: focusedDisplay)!)!.columns.flatMap(\.windows).map(\.pid), [7]
        )
    }
}

final class WindowEventRouterTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!
    private var router: WindowEventRouter!
    private var id: WindowID!
    private var element: AXUIElement!

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        let scheduler = scheduler!
        discovery = DiscoveryService(context: world.discoveryContext(), scheduler: scheduler)
        router = WindowEventRouter(
            context: world.routerContext(now: { scheduler.now }), discovery: discovery, scheduler: scheduler
        )
        world.displaySnapshots = [DisplaySnapshot(id: DisplayID(1), frame: EventWorld.screen, visibleFrame: EventWorld.screen)]
        discovery.syncDisplays()
        world.regular = [7]
        world.running = [7]
        router.rebuild()
        let window = discovered(pid: 7)
        world.scan = SystemWindowDiscoveryResult(windows: [window], completePIDs: [7])
        discovery.enumerateAndPlace()
        id = world.registered[0].id
        element = window.element
        world.reflows = 0
    }

    private func send(_ kind: SystemWindowEvent.Kind, pid: pid_t = 7, element: AXUIElement? = nil) {
        world.port!.deliver(SystemWindowEvent(kind: kind, pid: pid, label: "App", element: element))
        scheduler.runPending()
    }

    // MARK: Observers

    func testRebuildAttachesRunningAppsAndStopsThePreviousPort() {
        let first = world.port!
        XCTAssertEqual(first.attachCalls, [7])
        XCTAssertEqual(first.watched, [7], "registration watches the new window")

        world.regular = [7, 8]
        router.rebuild()

        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(world.port!.attachCalls, [7, 8])
    }

    func testSyncDetachesVanishedAppsAndReportsRefusals() {
        world.port!.attachResults[8] = [false]
        world.regular = [8]
        router.syncObservers()

        XCTAssertEqual(world.port!.detached, [7])
        XCTAssertEqual(world.console, ["[gio] observation refused: pid 8"])
        XCTAssertTrue(world.logs.contains { $0.1 == "observation refused for 1 app(s)" })

        // Activation gives a refused app another chance.
        send(.appActivated, pid: 8)
        XCTAssertEqual(world.port!.attachCalls.filter { $0 == 8 }.count, 2)
    }

    func testEventsHopToTheSessionQueue() {
        world.port!.deliver(SystemWindowEvent(kind: .window(.destroyed), pid: 7, label: "App", element: element))
        XCTAssertEqual(world.registered.count, 1)
        scheduler.runPending()
        XCTAssertTrue(world.registered.isEmpty)
    }

    // MARK: Launch, terminate, activation

    func testLaunchedAppAttachIsRetriedThenItsWindowsRegister() {
        world.regular = [7, 9]
        world.port!.attachResults[9] = [false, false]
        world.classify = [:]
        world.scan = SystemWindowDiscoveryResult(windows: [discovered(pid: 9)], completePIDs: [9])

        send(.appLaunched, pid: 9)
        XCTAssertEqual(world.port!.attachCalls.filter { $0 == 9 }.count, 1)
        scheduler.advance(by: 0.25)
        XCTAssertEqual(world.port!.attachCalls.filter { $0 == 9 }.count, 2)
        scheduler.advance(by: 0.5)

        XCTAssertEqual(world.port!.attachCalls.filter { $0 == 9 }.count, 3)
        XCTAssertEqual(world.scans.last, 9)
        XCTAssertTrue(world.registered.contains { $0.pid == 9 })
        XCTAssertEqual(world.reflows, 1)
    }

    func testLaunchedAppRefusedAfterEveryRetry() {
        world.regular = [7, 9]
        world.port!.attachResults[9] = Array(repeating: false, count: 5)

        send(.appLaunched, pid: 9)
        scheduler.advance(by: 10)

        XCTAssertEqual(world.port!.attachCalls.filter { $0 == 9 }.count, 5)
        XCTAssertEqual(world.console.last, "[gio] observation refused: pid 9")
        XCTAssertFalse(world.registered.contains { $0.pid == 9 })
    }

    func testLaunchOfANonRegularAppIsIgnored() {
        send(.appLaunched, pid: 9)
        XCTAssertFalse(world.port!.attachCalls.contains(9))
    }

    func testTerminateDetachesAndPurges() {
        send(.appTerminated)

        XCTAssertEqual(world.port!.detached, [7])
        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.forgottenApps, [7])
        XCTAssertEqual(world.reflows, 1)
    }

    func testActivationAdoptsFocusUpdatesTheDimAndRetriesAMissingTap() {
        send(.appActivated)
        XCTAssertEqual(world.focusRequests.map(\.0), [.activation])
        XCTAssertEqual(world.dimUpdates, 1)
        XCTAssertTrue(world.scheduledReflows.isEmpty)

        world.tapMissing = true
        send(.appActivated)
        XCTAssertEqual(world.scheduledReflows, [true])
    }

    /// PF-U: Gio turns `.regular` while its main window is open, so the
    /// running set, launch and activation all name its own pid. Observing
    /// it is AX on in-process elements (rule 4: AppKit runs on the calling
    /// thread and crashes) and subscribes Gio to its own overlay panels.
    func testOwnPidIsNeverObserved() {
        world.regular = [7, EventWorld.ownPID]
        router.syncObservers()
        send(.appActivated, pid: EventWorld.ownPID)
        send(.appLaunched, pid: EventWorld.ownPID)
        scheduler.advance(by: 10)

        XCTAssertFalse(world.port!.attachCalls.contains(EventWorld.ownPID))
        XCTAssertTrue(world.console.isEmpty, "not a refusal either")
    }

    // MARK: Window events

    func testOwnPidWindowsAreNeverRegisteredFromEvents() {
        let own = AXUIElementCreateApplication(4243)
        world.classify[EventWorld.ownPID] = [discovered(pid: EventWorld.ownPID), discovered(pid: EventWorld.ownPID)]

        send(.window(.windowCreated), pid: EventWorld.ownPID, element: own)
        send(.window(.deminiaturized), pid: EventWorld.ownPID, element: own)
        scheduler.advance(by: 5)

        XCTAssertFalse(world.registered.contains { $0.pid == EventWorld.ownPID })
    }

    func testDestroyedWindowIsReportedClosingBeforeItIsForgotten() {
        send(.window(.destroyed), element: element)

        XCTAssertEqual(world.closing.map(\.0), [[id]])
        XCTAssertEqual(world.closing.first?.1, true, "reported while its record still exists")
    }

    func testDestroyedWindowIsPurgedImmediately() {
        send(.window(.destroyed), element: element)

        XCTAssertTrue(world.registered.isEmpty)
        XCTAssertEqual(world.forgotten, [id])
        XCTAssertEqual(world.reflows, 1)
        XCTAssertTrue(world.scheduledReflows.isEmpty, "no rescan, no debounce")
    }

    func testMotionEchoesAreDroppedBeforeAnyLookup() {
        world.animating = [7]
        let lookups = world.knownLookups
        send(.window(.moved), element: element)
        send(.window(.resized), element: element)

        XCTAssertEqual(world.knownLookups, lookups)
        XCTAssertTrue(world.scheduledReflows.isEmpty)

        send(.window(.destroyed), element: element)
        XCTAssertTrue(world.registered.isEmpty, "only frame events are motion echoes")
    }

    func testBusyZoomDropsItsEvents() {
        world.zoomBusy = [id]
        send(.window(.moved), element: element)
        XCTAssertTrue(world.scheduledReflows.isEmpty)
        XCTAssertTrue(world.frameReads.isEmpty)
    }

    func testEchoSuppressionSkipsTheReadAndEchoesAreIgnored() {
        world.suppressed = [id]
        send(.window(.moved), element: element)
        XCTAssertTrue(world.frameReads.isEmpty)
        XCTAssertTrue(world.scheduledReflows.isEmpty)

        world.suppressed = []
        world.echoes = [id]
        send(.window(.moved), element: element)
        XCTAssertEqual(world.frameReads, [id])
        XCTAssertTrue(world.scheduledReflows.isEmpty)
        XCTAssertEqual(world.dragHolds, 0)
    }

    func testForeignMoveHoldsTheDimAndRelayouts() {
        send(.window(.moved), element: element)
        XCTAssertEqual(world.dragHolds, 1)
        XCTAssertEqual(world.trustInvalidated.last, id)
        XCTAssertEqual(world.zoomForgotten, [id])
        XCTAssertTrue(world.tileabilityInvalidated.isEmpty)
        XCTAssertEqual(world.scheduledReflows, [false])

        send(.window(.resized), element: element)
        XCTAssertEqual(world.tileabilityInvalidated, [id])
    }

    func testMinimizeAndRestore() {
        send(.window(.miniaturized), element: element)
        XCTAssertEqual(world.registered.first?.isMinimized, true)
        send(.window(.deminiaturized), element: element)
        XCTAssertEqual(world.registered.first?.isMinimized, false)
        XCTAssertEqual(world.reflows, 2)
    }

    func testTitleUpdatesTheRecordWithoutLoggingIt() {
        world.titles[7] = "new secret"
        send(.window(.titleChanged), element: element)
        scheduler.advance(by: WindowEventRouter.titleCoalesce)

        XCTAssertEqual(world.registered.first?.title, "new secret")
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret") })
        XCTAssertFalse(world.console.contains { $0.contains("secret") })
    }

    /// PF-W: terminals and pages retitle themselves several times a second
    /// (spinners, counters), all day. Each change was one AX read into the
    /// app; now a window's title is read at most once per `titleCoalesce`,
    /// with the value it has then.
    func testTitleChangesAreReadOncePerCoalesceWindowWithTheLatestValue() {
        for step in 0..<10 {
            world.titles[7] = "secret \(step)"
            send(.window(.titleChanged), element: element)
            scheduler.advance(by: 0.1)
        }
        XCTAssertEqual(world.titleReads, 1)
        XCTAssertEqual(world.registered.first?.title, "secret 9")
        scheduler.advance(by: 10)
        XCTAssertEqual(world.titleReads, 1, "nothing pending once read")
    }

    func testFocusedWindowChangeRequestsAdoption() {
        send(.window(.focusedWindowChanged), element: element)
        XCTAssertEqual(world.focusRequests.map(\.0), [.focusChanged])
    }

    func testUnknownElementsAreRegisteredOnlyForCreateAndDeminimize() {
        let stranger = AXUIElementCreateApplication(4244)
        world.classify[7] = [discovered(pid: 7)]
        send(.window(.moved), element: stranger)
        XCTAssertEqual(world.registered.count, 1)
        send(.window(.windowCreated), element: stranger)
        XCTAssertEqual(world.registered.count, 2)
    }

    // MARK: Snap-back cap (FI-10)

    /// Gio writes the window, the app restores its own frame `after` later.
    private func snapBack(after delay: TimeInterval = 0.5) {
        world.lastWrites[id] = scheduler.now
        scheduler.advance(by: delay)
        send(.window(.moved), element: element)
    }

    func testAnAppThatKeepsSnappingBackYieldsAndIsNoLongerFought() {
        snapBack()
        snapBack()
        XCTAssertEqual(world.scheduledReflows, [false, false], "each snap-back is written back")
        XCTAssertEqual(world.registered.first?.mode, .tiled)
        snapBack()
        XCTAssertEqual(world.registered.first?.mode, .floating)
        XCTAssertEqual(world.registered.first?.floatReason, .appControlled)
        XCTAssertEqual(world.scheduledReflows, [false, false, false], "one pass closes the gap")
        let warnings = world.logs.filter { $0.0 == .warn && $0.1.hasPrefix("window yields to app") }
        XCTAssertEqual(warnings.map(\.1), ["window yields to app id=7:\(id.elementID) app=Code snapBacks=3"])
        XCTAssertTrue(world.session.manager.currentWorkspace().columns.flatMap(\.windows).contains(id), "still a member")

        let holds = world.dragHolds
        for _ in 0..<5 {
            snapBack()
        }
        XCTAssertEqual(world.scheduledReflows.count, 3, "the app keeps its frame: no more passes")
        XCTAssertEqual(world.dragHolds, holds)
        XCTAssertEqual(world.logs.filter { $0.1.hasPrefix("window yields to app") }.count, 1, "warned once")
        XCTAssertFalse(world.logs.contains { $0.1.contains("secret") })
    }

    func testTilingAYieldedWindowAgainStartsANewCount() throws {
        for _ in 0..<3 {
            snapBack()
        }
        XCTAssertEqual(try world.session.registry.toggleFloating(for: id), .tiled)
        let before = world.scheduledReflows.count
        snapBack()
        snapBack()
        XCTAssertEqual(world.registered.first?.mode, .tiled)
        XCTAssertEqual(world.scheduledReflows.count, before + 2)
        snapBack()
        XCTAssertEqual(world.registered.first?.floatReason, .appControlled, "the fight came back")
    }

    func testAUserDragOrAnAppMoveLongAfterGiosWriteNeverYields() {
        world.mouseDown = true
        for _ in 0..<5 {
            snapBack()
        }
        world.mouseDown = false
        for _ in 0..<5 {
            snapBack(after: 2)
        }
        XCTAssertEqual(world.registered.first?.mode, .tiled)
        XCTAssertEqual(world.scheduledReflows.count, 10, "every move is still laid out again")
    }

    func testForgettingAWindowDropsItsSnapBacks() {
        snapBack()
        snapBack()
        router.forgetSnapBacks(id)
        snapBack()
        XCTAssertEqual(world.registered.first?.mode, .tiled)
    }

    // MARK: Late frame re-check (FI-11)

    /// What the fake reads for every window.
    private let observed = CGRect(x: 0, y: 0, width: 100, height: 100)
    /// Narrower than what the app keeps: a late minimum width.
    private let narrow = CGRect(x: 0, y: 0, width: 80, height: 100)

    /// Gio writes the window (`written`); 0.2 s later, inside the echo
    /// window, the app applies its own size; the echo window ends.
    private func lateResize(written: CGRect? = nil) {
        world.lastWrites[id] = scheduler.now
        world.writtenFrames[id] = written ?? narrow
        world.suppressed = [id]
        scheduler.advance(by: 0.2)
        send(.window(.resized), element: element)
        world.suppressed = []
        scheduler.advance(by: 0.5)
    }

    func testAResizeHiddenByTheEchoWindowIsCheckedOnceWhenItEnds() {
        world.lastWrites[id] = 0
        world.writtenFrames[id] = narrow
        world.suppressed = [id]
        scheduler.advance(by: 0.2)
        send(.window(.resized), element: element)
        send(.window(.moved), element: element)
        XCTAssertTrue(world.frameReads.isEmpty, "still no read inside the echo window")
        XCTAssertTrue(world.scheduledReflows.isEmpty)
        world.suppressed = []
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.frameReads, [id], "one re-check per window")
        XCTAssertEqual(world.lateClampAsks.map(\.0), [id])
        XCTAssertEqual(world.lateClampAsks.first?.1, narrow)
        XCTAssertEqual(world.lateClampAsks.first?.2, observed)
        XCTAssertEqual(world.trustInvalidated.last, id, "not where Gio put it: read again")
        XCTAssertEqual(world.scheduledReflows, [false])
    }

    /// A late clamp can only follow a size write, which raises `.resized`;
    /// the moves of every scroll are not worth an extra read each.
    func testAMoveHiddenByTheEchoWindowIsNotCheckedAgain() {
        world.lastWrites[id] = 0
        world.writtenFrames[id] = narrow
        world.suppressed = [id]
        scheduler.advance(by: 0.2)
        send(.window(.moved), element: element)
        world.suppressed = []
        scheduler.advance(by: 1)
        XCTAssertTrue(world.frameReads.isEmpty)
        XCTAssertTrue(world.scheduledReflows.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0, "nothing scheduled")
    }

    func testALateCheckFindingGiosSizeOrAPurgedWindowDoesNothing() {
        lateResize(written: observed)
        lateResize(written: observed.offsetBy(dx: 39, dy: -30))
        XCTAssertEqual(world.frameReads, [id, id])
        XCTAssertTrue(world.lateClampAsks.isEmpty, "the size landed (a parking or menu-bar clamp moves only)")
        XCTAssertTrue(world.scheduledReflows.isEmpty)

        world.lastWrites[id] = scheduler.now
        world.writtenFrames[id] = narrow
        world.suppressed = [id]
        send(.window(.resized), element: element)
        send(.window(.destroyed), element: element)
        world.suppressed = []
        scheduler.advance(by: 1)
        XCTAssertEqual(world.frameReads, [id, id], "purged: no read")
    }

    func testALateCheckWaitsForGiosNextWriteToEnd() {
        world.lastWrites[id] = 0
        world.writtenFrames[id] = narrow
        world.suppressed = [id]
        send(.window(.resized), element: element)
        scheduler.advance(by: 0.3)
        world.lastWrites[id] = 0.3
        scheduler.advance(by: 0.2)
        XCTAssertTrue(world.frameReads.isEmpty, "Gio wrote it again: its echo window runs")
        world.suppressed = []
        scheduler.advance(by: 0.5)
        XCTAssertEqual(world.frameReads, [id])
    }

    func testALearnableLateClampIsLearnedOnceAndStops() {
        world.learnsLateClamp = true
        lateResize()
        XCTAssertEqual(world.lateClampAsks.map(\.0), [id])
        XCTAssertTrue(world.scheduledReflows.isEmpty, "the host relayouts with the learned minimum")
        // The relayout writes the learned size, which lands.
        for _ in 0..<4 {
            lateResize(written: observed)
        }
        XCTAssertEqual(world.lateClampAsks.count, 1)
        XCTAssertEqual(world.registered.first?.mode, .tiled)
        XCTAssertFalse(world.logs.contains { $0.1.hasPrefix("window yields to app") })
    }

    func testAnUnlearnableLateClampIsAFightTheSnapBackCapEnds() {
        for _ in 0..<3 {
            lateResize()
        }
        XCTAssertEqual(world.registered.first?.floatReason, .appControlled)
        XCTAssertEqual(world.scheduledReflows.count, 3, "two write-backs, then the gap closes")
        let reads = world.frameReads.count
        lateResize()
        XCTAssertEqual(world.frameReads.count, reads, "a yielded window is not re-checked")
        XCTAssertEqual(world.scheduledReflows.count, 3)
    }

    func testALateChangeDuringAUserDragIsNeitherLearnedNorCounted() {
        world.mouseDown = true
        for _ in 0..<4 {
            lateResize()
        }
        XCTAssertTrue(world.lateClampAsks.isEmpty)
        XCTAssertEqual(world.registered.first?.mode, .tiled)
        XCTAssertEqual(world.scheduledReflows.count, 4)
    }
}
