@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import XCTest
@testable import GioSession

/// MM-04: the live arrangement (built-in primary at the origin, an external
/// display left of it, bottom 224 pt lower, top 47 pt higher).
private enum Live {
    static let builtIn = DisplayID(1)
    static let external = DisplayID(3)
    static let builtInFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    static let builtInVisible = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    static let externalFrame = CGRect(x: -2160, y: -224, width: 2160, height: 1440)
    static let builtInSnapshot = DisplaySnapshot(
        id: builtIn, frame: builtInFrame, visibleFrame: builtInVisible, scale: 2, refreshRate: 120
    )
    static let externalSnapshot = DisplaySnapshot(
        id: external, frame: externalFrame, visibleFrame: externalFrame, scale: 1, refreshRate: 60
    )
}

final class MultiDisplayHotPlugTests: XCTestCase {
    private var world: EventWorld!
    private var scheduler: ManualScheduler!
    private var discovery: DiscoveryService!

    override func setUp() {
        world = EventWorld()
        scheduler = ManualScheduler()
        discovery = DiscoveryService(context: world.discoveryContext(), scheduler: scheduler)
    }

    private var manager: WorkspaceManager { world.session.manager }

    // MARK: Logging

    func testEveryDisplaySyncLogsTheConfiguration() {
        world.displaySnapshots = [Live.builtInSnapshot, Live.externalSnapshot]
        discovery.syncDisplays()
        let info = world.logs.filter { $0.0 == .info }.map(\.1)
        let builtInStack = manager.stack(on: Live.builtIn).map { "\($0.id.rawValue)" }.joined(separator: ",")
        let externalStack = manager.stack(on: Live.external).map { "\($0.id.rawValue)" }.joined(separator: ",")
        XCTAssertEqual(info, [
            "displays count=2",
            "display index=1 id=3 frame=(-2160,-224,2160,1440) visible=(-2160,-224,2160,1440) scale=1 hz=60"
                + " primary=false number=2 shown=\(manager.activeID(on: Live.external)!.rawValue) stack=\(externalStack)",
            "display index=2 id=1 frame=(0,0,1800,1169) visible=(0,0,1800,1130) scale=2 hz=120"
                + " primary=true number=1 shown=\(manager.activeID(on: Live.builtIn)!.rawValue) stack=\(builtInStack)",
        ])
        XCTAssertTrue(world.logs.contains { $0 == (.debug, "display flip primaryHeight=1169 primary=1") })
    }

    func testAnEmptyScreenListKeepsTheConnectedDisplays() {
        world.displaySnapshots = [Live.externalSnapshot, Live.builtInSnapshot]
        discovery.syncDisplays()
        world.displaySnapshots = []
        discovery.syncDisplays()
        XCTAssertEqual(world.displays.allDisplays().map(\.id), [Live.external, Live.builtIn])
        XCTAssertEqual(manager.displayIDs, [Live.external, Live.builtIn])
        XCTAssertEqual(world.displayChanges, 1, "nothing changed, nothing is distrusted")
    }

    // MARK: Coalescing

    func testABurstOfScreenNotificationsSyncsOnce() {
        world.displaySnapshots = [Live.builtInSnapshot]
        discovery.noteDisplayChange()
        scheduler.advance(by: 0.1)
        discovery.noteDisplayChange()
        scheduler.advance(by: 0.1)
        discovery.noteDisplayChange()
        XCTAssertEqual(world.displayChanges, 0, "nothing syncs while the burst lasts")
        XCTAssertEqual(world.reflows, 0)
        scheduler.advance(by: DiscoveryService.displayChangeDelay)
        XCTAssertEqual(world.displayChanges, 1)
        XCTAssertEqual(world.reflows, 1)
        scheduler.advance(by: 5)
        XCTAssertEqual(world.displayChanges, 1)
    }

    // MARK: Hot-plug sequence

    private let ghostty = WindowRule(app: "Ghostty", openOnWorkspace: "Code", follow: .never)
    private let chrome = WindowRule(app: "Google Chrome", openOnWorkspace: "Browsers", follow: .never)

    /// The host's pass, without the writes: shown-workspace sync, the
    /// inactive plan, then every display.
    private func pass(_ planner: ReflowPlanner) -> ReflowPlan {
        for display in world.displays.allDisplays() {
            if let active = manager.activeID(on: display.id), active != display.workspace {
                world.displays.assign(display.id, workspace: active)
            }
        }
        let modes = Dictionary(uniqueKeysWithValues: world.registered.map { ($0.id, $0.mode) })
        let inactive = planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
            manager: manager, registry: world.session.registry
        )
        let config = world.session.config
        let plan = planner.plan(
            .init(
                displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames, manager: manager,
                modes: modes, engine: { ScrollableLayoutEngine(config: config.makeLayoutConfig()) },
                centering: CenterRequest(mode: .always, previouslyFocused: nil), animating: false, duration: 0.2
            ),
            inactive: inactive, zoomTargets: { plan, _ in plan.visible }
        )
        for outcome in plan.displays {
            world.session.manager.update(outcome.workspace)
            world.displays.updateViewport(outcome.viewport, for: outcome.display)
        }
        return plan
    }

    /// Every window ends inside the display that owns its workspace (shown)
    /// or parked off every other display (hidden); nothing straddles.
    private func assertEveryWindowOnItsDisplay(_ plan: ReflowPlan, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let frames = Dictionary(uniqueKeysWithValues: world.displays.allDisplays().map { ($0.id, $0.frame) })
        var owner: [WindowID: DisplayID] = [:]
        for display in manager.displayIDs {
            for workspace in manager.stack(on: display) {
                for id in workspace.columns.flatMap(\.windows) {
                    owner[id] = display
                }
            }
        }
        var seen = Set<WindowID>()
        for parking in plan.plans {
            for (id, frame) in parking.visible {
                seen.insert(id)
                let display = try? XCTUnwrap(owner[id].flatMap { frames[$0] }, "\(label) \(id.pid) has no display", file: file, line: line)
                for (other, otherFrame) in frames where other != owner[id] {
                    XCTAssertFalse(frame.intersects(otherFrame), "\(label) \(id.pid) straddles \(frame)", file: file, line: line)
                }
                XCTAssertTrue(display.map { $0.intersects(frame) } ?? false, "\(label) \(id.pid) off its display \(frame)", file: file, line: line)
            }
            for (id, target) in parking.parked {
                seen.insert(id)
                XCTAssertEqual(target.display, owner[id].flatMap { frames[$0] }, "\(label) \(id.pid) parks off another display", file: file, line: line)
                for (other, otherFrame) in frames where other != owner[id] {
                    XCTAssertFalse(target.frame.intersects(otherFrame), "\(label) \(id.pid) parked on \(other)", file: file, line: line)
                }
            }
        }
        XCTAssertEqual(seen, Set(world.registered.map(\.id)), "\(label): every window is placed", file: file, line: line)
    }

    func testConnectingAndDisconnectingTheExternalKeepsEveryWindowOnItsDisplay() {
        world.session.config.workspaces = [
            WorkspaceDefinition(name: "Code", display: .index(2)), WorkspaceDefinition(name: "Browsers"),
        ]
        world.session.config.rules = [ghostty, chrome]
        // 1. The built-in alone: `Code` (display 2) falls back to the main display.
        world.displaySnapshots = [Live.builtInSnapshot]
        discovery.syncDisplays()
        XCTAssertEqual(manager.location(of: manager.namedWorkspaceID("Code")!)?.display, Live.builtIn)
        // AX frames (top-left origin of the 1169 pt primary).
        world.scan = SystemWindowDiscoveryResult(
            windows: [
                discovered(pid: 7, frame: CGRect(x: 8, y: 47, width: 888, height: 1114), app: "Ghostty"),
                discovered(pid: 8, frame: CGRect(x: 8, y: 47, width: 888, height: 1114), app: "Google Chrome"),
                discovered(pid: 9, frame: CGRect(x: 904, y: 47, width: 888, height: 1114), app: "Google Chrome"),
                discovered(pid: 10, frame: CGRect(x: 904, y: 47, width: 888, height: 1114), app: "Google Chrome"),
                discovered(pid: 11, frame: CGRect(x: 300, y: 100, width: 888, height: 900), app: "Activity Monitor"),
            ],
            completePIDs: [7, 8, 9, 10, 11]
        )
        world.running = [7, 8, 9, 10, 11]
        discovery.enumerateAndPlace()
        let planner = ReflowPlanner(context: .init(
            physicalFrames: { [unowned self] in
                Dictionary(uniqueKeysWithValues: world.registered.map { ($0.id, $0.frame) })
            },
            readFrame: { _ in nil }, storePhysicalFrame: { _, _ in }
        ))
        assertEveryWindowOnItsDisplay(pass(planner), "built-in only")

        // 2. Connect the external: `Code` moves to display 2 and shows there.
        world.displaySnapshots = [Live.externalSnapshot, Live.builtInSnapshot]
        discovery.syncDisplays()
        let code = manager.namedWorkspaceID("Code")!
        XCTAssertEqual(manager.location(of: code)?.display, Live.external)
        XCTAssertEqual(manager.activeID(on: Live.external), code)
        XCTAssertEqual(
            world.displays.allDisplays().map(\.workspace),
            [manager.activeID(on: Live.external), manager.activeID(on: Live.builtIn)],
            "each display points at its own active workspace right after the sync"
        )
        let connected = pass(planner)
        XCTAssertEqual(connected.displays.map(\.display), [Live.external, Live.builtIn])
        assertEveryWindowOnItsDisplay(connected, "connected")
        let ghosttyID = world.registered.first { $0.application == "Ghostty" }!.id
        XCTAssertTrue(connected.plans[0].visible[ghosttyID].map(Live.externalFrame.contains) ?? false)

        // 3. Disconnect: `Code` comes back to the built-in, no stale display.
        world.displaySnapshots = [Live.builtInSnapshot]
        discovery.syncDisplays()
        XCTAssertEqual(manager.location(of: code)?.display, Live.builtIn)
        XCTAssertEqual(manager.displayIDs, [Live.builtIn])
        XCTAssertEqual(world.displays.allDisplays().map(\.id), [Live.builtIn])
        XCTAssertEqual(Array(world.visibleFrames.keys), [Live.builtIn])
        let disconnected = pass(planner)
        XCTAssertEqual(disconnected.displays.map(\.display), [Live.builtIn])
        assertEveryWindowOnItsDisplay(disconnected, "disconnected")
    }

    // MARK: Overview display (Alt+O)

    func testTheOverviewFocusesTheDisplayTheUserIsOn() {
        world.displaySnapshots = [Live.externalSnapshot, Live.builtInSnapshot]
        discovery.syncDisplays()
        XCTAssertEqual(manager.focusedDisplay, Live.builtIn)
        var manager = self.manager
        let choice = ActionApplier.focusOverviewDisplay(
            manager: &manager, focusedWindowFrame: CGRect(x: -1076, y: -216, width: 1068, height: 1424),
            cursor: nil, displays: world.displays.allDisplays()
        )
        XCTAssertEqual(choice?.display, Live.external)
        XCTAssertEqual(choice?.reason, .focusedWindow)
        XCTAssertEqual(manager.focusedDisplay, Live.external, "workspace picks act on the overview's display")
        let cursor = ActionApplier.focusOverviewDisplay(
            manager: &manager, focusedWindowFrame: nil, cursor: CGPoint(x: 900, y: 500),
            displays: world.displays.allDisplays()
        )
        XCTAssertEqual(cursor?.display, Live.builtIn)
        XCTAssertEqual(cursor?.reason, .cursor)
        XCTAssertEqual(manager.focusedDisplay, Live.builtIn)
    }
}

/// MM-04: far-side parks (the near edge is another display) and windows
/// coming back from one jump instead of flying across the display.
final class FarSideParkingMotionTests: XCTestCase {
    private func world() -> (ReflowWorld, [WindowID]) {
        let world = ReflowWorld(frames: [(Live.external, Live.externalFrame), (Live.builtIn, Live.builtInFrame)])
        world.visibleFrames = [Live.external: Live.externalFrame, Live.builtIn: Live.builtInVisible]
        _ = world.session.manager.focusDisplay(Live.external)
        XCTAssertEqual(world.session.manager.focusedDisplay, Live.external)
        let ids = world.addColumns(3, on: Live.external)
        // Where they were: laid out at offset 0 (the third one on the built-in).
        for (index, id) in ids.enumerated() {
            world.physicalFrames[id] = CGRect(x: -2152 + 1076 * CGFloat(index), y: -216, width: 1068, height: 1424)
        }
        return (world, ids)
    }

    func testAPeekThatWouldStraddleParksFarSideWithoutAFlight() throws {
        let (world, ids) = world()
        world.focusColumn(1)
        let (_, plan) = PlannerHarness(world: world).run(
            animating: true, settings: AnimationsSectionConfig(),
            centering: CenterRequest(mode: .always, previouslyFocused: nil), zoomTargets: { plan, _ in plan.visible }
        )
        let parked = try XCTUnwrap(plan.plans[0].parked[ids[2]])
        XCTAssertTrue(parked.farSide)
        XCTAssertFalse(parked.frame.intersects(Live.builtInFrame))
        XCTAssertFalse(plan.animations.contains { $0.id == ids[2] }, "no flight across the external")
        XCTAssertEqual(plan.prepositions[ids[2]], parked.frame, "it jumps when the motion starts")
        // 2026-10-14 recording: a column leaving by the shared edge vanished
        // at the first overlay frame. Its snapshot layer slides out to its
        // strip frame past that edge, clipped by its own display's overlay.
        let path = try XCTUnwrap(plan.jumps[ids[2]])
        XCTAssertEqual(path.from, world.physicalFrames[ids[2]])
        XCTAssertEqual(path.display, Live.externalFrame)
        XCTAssertGreaterThan(path.to.maxX, Live.externalFrame.maxX, "past the shared edge")
        XCTAssertEqual(path.to.size, path.from.size)
        XCTAssertTrue(plan.animations.contains { $0.id == ids[0] }, "the others still slide")
    }

    func testAWindowComingBackFromAFarSideParkJumpsToItsTile() throws {
        let (world, ids) = world()
        world.focusColumn(1)
        let harness = PlannerHarness(world: world)
        let (_, first) = harness.run(
            animating: false, settings: AnimationsSectionConfig(),
            centering: CenterRequest(mode: .always, previouslyFocused: nil), zoomTargets: { plan, _ in plan.visible }
        )
        for parking in first.plans {
            world.physicalFrames.merge(parking.visible) { _, new in new }
            world.physicalFrames.merge(parking.parked.mapValues(\.frame)) { _, new in new }
        }
        world.focusColumn(2)
        let (_, second) = harness.run(
            animating: true, settings: AnimationsSectionConfig(), centering: .none,
            zoomTargets: { plan, _ in plan.visible }
        )
        let tile = try XCTUnwrap(second.plans[0].visible[ids[2]])
        XCTAssertTrue(Live.externalFrame.contains(tile))
        XCTAssertFalse(second.animations.contains { $0.id == ids[2] })
        XCTAssertEqual(second.prepositions[ids[2]], tile)
        let back = try XCTUnwrap(second.jumps[ids[2]])
        XCTAssertEqual(back.to, tile)
        XCTAssertGreaterThan(back.from.maxX, Live.externalFrame.maxX, "it enters by the shared edge")
        XCTAssertEqual(back.display, Live.externalFrame)
    }
}
