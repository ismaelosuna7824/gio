import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// Session state a reflow plans over: the planner reads it through its
/// context, the legacy reference (a verbatim copy of the pre-refactor
/// `performReflow` planning half) reads and writes it directly.
final class ReflowWorld: @unchecked Sendable {
    static let left = DisplayID(1)
    static let right = DisplayID(2)
    static let leftFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    static let rightFrame = CGRect(x: 1800, y: 0, width: 1600, height: 1000)

    var session = CommandSession()
    var displays = DisplayManager()
    var visibleFrames: [DisplayID: CGRect] = [:]
    var physicalFrames: [WindowID: CGRect] = [:]
    /// What an AX read of a never-placed window returns.
    var readable: [WindowID: CGRect] = [:]
    var reads: [WindowID] = []
    var modes: [WindowID: WindowMode] = [:]

    convenience init(twoDisplays: Bool = false) {
        self.init(frames: twoDisplays
            ? [(Self.left, Self.leftFrame), (Self.right, Self.rightFrame)]
            : [(Self.left, Self.leftFrame)])
    }

    /// MM-03: any arrangement (`left`/`right` are just the two IDs).
    init(frames: [(DisplayID, CGRect)]) {
        session.manager.syncDisplays(frames.map(\.0))
        for (id, frame) in frames {
            displays.connect(id, frame: frame, workspace: session.manager.activeID(on: id)!)
            visibleFrames[id] = frame.insetBy(dx: 0, dy: 20)
        }
    }

    /// Adds one single-window column per width to the current workspace.
    @discardableResult
    func addColumns(
        _ count: Int, pidBase: pid_t = 100, mode: WindowMode = .tiled, placed: Bool = true,
        on display: DisplayID? = nil
    ) -> [WindowID] {
        var workspace = display.flatMap { session.manager.activeID(on: $0) }
            .flatMap { session.manager.workspace(id: $0) } ?? session.manager.currentWorkspace()
        var added: [WindowID] = []
        for index in 0..<count {
            let pid = pidBase + pid_t(index)
            let id = WindowID(pid: pid, elementID: UInt64(pid))
            let frame = CGRect(x: 40 * index, y: 60, width: 900, height: 700)
            try? session.registry.register(ManagedWindow(
                id: id, pid: pid, application: "App\(pid)", title: "secret \(pid)", frame: frame, mode: mode
            ))
            var column = Column(id: ColumnID(UInt64(pid)), width: 0, windows: [id])
            column.focusedWindowIndex = 0
            workspace.columns.append(column)
            workspace.focusedColumn = workspace.columns.count - 1
            workspace.focusedWindow = id
            if placed {
                physicalFrames[id] = frame
            } else {
                readable[id] = frame
            }
            modes[id] = mode
            added.append(id)
        }
        session.manager.update(workspace)
        return added
    }

    func focusColumn(_ index: Int) {
        var workspace = session.manager.currentWorkspace()
        workspace.focusedColumn = index
        workspace.focusedWindow = workspace.columns[index].windows.first
        session.manager.update(workspace)
    }

    /// The host's `syncShownWorkspace`.
    func syncShown() {
        for display in displays.allDisplays() {
            if let active = session.manager.activeID(on: display.id), active != display.workspace {
                displays.assign(display.id, workspace: active)
            }
        }
    }

    func engine() -> ScrollableLayoutEngine {
        ScrollableLayoutEngine(config: session.config.makeLayoutConfig())
    }

    func read(_ id: WindowID) -> CGRect? {
        reads.append(id)
        return readable[id]
    }

    func copy() -> ReflowWorld {
        let other = ReflowWorld()
        other.session = session
        other.session.registry = WindowRegistry()
        for window in session.registry.managedWindows() {
            try? other.session.registry.register(window)
        }
        other.displays = displays
        other.visibleFrames = visibleFrames
        other.physicalFrames = physicalFrames
        other.readable = readable
        other.modes = modes
        return other
    }
}

/// Everything a pass leaves behind, for the equivalence check.
struct ReflowOutcome: Equatable {
    var plans: [ParkingPlan]
    var animations: [WindowAnimation]
    var prepositions: [WindowID: CGRect]
    var hovered: [WindowID: CGRect]
    var manager: WorkspaceManager
    var displays: DisplayManager
    var physicalFrames: [WindowID: CGRect]
    /// Sorted: frame reads follow dictionary order, which is arbitrary in
    /// both paths (each read is independent).
    var reads: [WindowID]
    var hiddenBook: HiddenWindowBook
}

/// Verbatim copy of the planning half of `SessionHost.performReflow` and
/// `planInactiveWorkspaces` before RF-10 (host fields → world fields).
final class LegacyReflowReference {
    private struct InactiveParkKey: Equatable {
        var frames: [WindowID: CGRect]
        var display: CGRect
        var others: [CGRect]
    }

    private var inactiveParking = PlanMemo<InactiveParkKey, [WindowID: ParkedTarget]>()
    var hiddenBook = HiddenWindowBook()
    let world: ReflowWorld

    init(world: ReflowWorld) {
        self.world = world
    }

    func run(
        animating: Bool, settings: AnimationsSectionConfig, centering: CenterRequest,
        zoomTargets: (ParkingPlan, CGRect) -> [WindowID: CGRect]
    ) -> ReflowOutcome {
        let modes = world.modes
        var plans: [ParkingPlan] = []
        var animations: [WindowAnimation] = []
        var prepositions: [WindowID: CGRect] = [:]
        var hovered: [WindowID: CGRect] = [:]
        let inactive = planInactiveWorkspaces()
        for (index, display) in world.displays.allDisplays().enumerated() {
            guard let workspace = world.session.manager.workspace(id: display.workspace) else {
                continue
            }
            let visible = world.visibleFrames[display.id] ?? display.frame
            guard let planned = try? planDisplayLayout(
                workspace: workspace, modes: modes, engine: world.engine(),
                viewport: visible, display: display.frame,
                otherDisplays: world.displays.allDisplays().filter { $0.id != display.id }.map(\.frame),
                centering: display.workspace == world.session.manager.currentID ? centering : .none
            ) else {
                continue
            }
            var displayPlan = planned.plan
            displayPlan.visible = zoomTargets(displayPlan, visible)
            plans.append(displayPlan)
            hovered.merge(displayPlan.visible) { first, _ in first }
            if animating {
                let carriesSwitch = index == 0
                let motionFrames = carriesSwitch
                    ? displayPlan.visible.merging(inactive.visible) { first, _ in first }
                    : displayPlan.visible
                learnPhysicalFrames(of: motionFrames.keys)
                let motion = planWorkspaceSwitchMotion(
                    current: world.physicalFrames, visible: motionFrames,
                    parked: displayPlan.parked, hidden: carriesSwitch ? inactive.parked : [:],
                    viewport: visible, display: display.frame, otherDisplays: [], duration: settings.duration
                )
                animations += motion.animations
                prepositions.merge(motion.prepositions) { _, new in new }
            }
            world.session.manager.update(planned.workspace)
            world.displays.updateViewport(
                Viewport(offset: planned.layout.viewportOffset, width: visible.width), for: display.id
            )
        }
        plans.append(inactive)
        if settings.curve == .spring {
            animations = animations.map { $0.springing(settings.spring) }
        }
        return ReflowOutcome(
            plans: plans, animations: animations, prepositions: prepositions, hovered: hovered,
            manager: world.session.manager, displays: world.displays,
            physicalFrames: world.physicalFrames, reads: world.reads.sorted(), hiddenBook: hiddenBook
        )
    }

    private func planInactiveWorkspaces() -> ParkingPlan {
        let all = world.displays.allDisplays()
        var plan = ParkingPlan(visible: [:], parked: [:])
        guard let hiddenDisplay = all.first else {
            return plan
        }
        let shown = Set(all.map(\.workspace))
        let windows = Dictionary(
            uniqueKeysWithValues: world.session.registry.managedWindows().map { ($0.id, $0) }
        )
        let hidden = world.session.manager.windows(outside: shown).filter {
            windows[$0].map { !$0.isMinimized } ?? false
        }
        learnPhysicalFrames(of: hidden)
        var frames: [WindowID: CGRect] = [:]
        for id in hidden {
            guard let frame = world.physicalFrames[id] else {
                continue
            }
            frames[id] = frame
            if windows[id]?.mode == .floating {
                hiddenBook.hide(id, from: frame)
            }
        }
        let others = all.filter { $0.id != hiddenDisplay.id }.map(\.frame)
        plan.parked = inactiveParking.value(
            for: InactiveParkKey(frames: frames, display: hiddenDisplay.frame, others: others)
        ) {
            planHiddenWindows(frames: frames, display: hiddenDisplay.frame, otherDisplays: others)
        }
        let active = shown.flatMap { id in
            (world.session.manager.workspace(id: id)?.columns ?? []).flatMap(\.windows)
        }
        let floating = active.filter { windows[$0]?.mode == .floating }
        plan.visible = hiddenBook.frames(of: floating)
        for (id, frame) in plan.visible {
            if let physical = world.physicalFrames[id],
               abs(physical.minX - frame.minX) <= 1, abs(physical.minY - frame.minY) <= 1
            {
                _ = hiddenBook.reveal([id])
            }
        }
        return plan
    }

    private func learnPhysicalFrames(of ids: some Sequence<WindowID>) {
        for id in ids where world.physicalFrames[id] == nil {
            if let frame = world.read(id) {
                world.physicalFrames[id] = frame
            }
        }
    }
}

/// Runs the new planner the way the host does now.
final class PlannerHarness {
    let world: ReflowWorld
    let planner: ReflowPlanner

    init(world: ReflowWorld) {
        self.world = world
        planner = ReflowPlanner(context: .init(
            physicalFrames: { world.physicalFrames },
            readFrame: { world.read($0) },
            storePhysicalFrame: { world.physicalFrames[$0] = $1 }
        ))
    }

    @discardableResult
    func run(
        animating: Bool, settings: AnimationsSectionConfig, centering: CenterRequest,
        zoomTargets: (ParkingPlan, CGRect) -> [WindowID: CGRect]
    ) -> (ReflowOutcome, ReflowPlan) {
        let inactive = planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
            manager: world.session.manager, registry: world.session.registry
        )
        let pass = planner.plan(
            .init(
                displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
                manager: world.session.manager, modes: world.modes, engine: { self.world.engine() },
                centering: centering, animating: animating, duration: settings.duration
            ),
            inactive: inactive, zoomTargets: zoomTargets
        )
        for outcome in pass.displays {
            world.session.manager.update(outcome.workspace)
            world.displays.updateViewport(outcome.viewport, for: outcome.display)
        }
        let animations = ReflowPlanner.applyingCurve(pass.animations, settings: settings)
        return (
            ReflowOutcome(
                plans: pass.plans, animations: animations, prepositions: pass.prepositions, hovered: pass.hovered,
                manager: world.session.manager, displays: world.displays,
                physicalFrames: world.physicalFrames, reads: world.reads.sorted(), hiddenBook: planner.hiddenBook
            ),
            pass
        )
    }
}

final class ReflowPlannerTests: XCTestCase {
    private let identity: (ParkingPlan, CGRect) -> [WindowID: CGRect] = { plan, _ in plan.visible }

    /// Runs the legacy reference and the planner on two copies of `world`
    /// (twice, so the memo and the hidden book carry over) and compares.
    @discardableResult
    private func assertEquivalent(
        _ world: ReflowWorld, animating: Bool = true,
        settings: AnimationsSectionConfig = AnimationsSectionConfig(),
        centering: CenterRequest = .none,
        zoomTargets: ((ParkingPlan, CGRect) -> [WindowID: CGRect])? = nil,
        between: ((ReflowWorld) -> Void)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ReflowPlan {
        let legacyWorld = world.copy()
        let newWorld = world.copy()
        let legacy = LegacyReflowReference(world: legacyWorld)
        let harness = PlannerHarness(world: newWorld)
        let targets = zoomTargets ?? identity
        var lastPlan = ReflowPlan()
        for round in 0..<2 {
            let old = legacy.run(animating: animating, settings: settings, centering: centering, zoomTargets: targets)
            let (new, plan) = harness.run(
                animating: animating, settings: settings, centering: centering, zoomTargets: targets
            )
            XCTAssertEqual(new, old, "round \(round)", file: file, line: line)
            lastPlan = plan
            between?(legacyWorld)
            between?(newWorld)
        }
        return lastPlan
    }

    // MARK: Equivalence with the pre-refactor path

    func testScrollToFocusedColumnMatchesLegacyAndScrolls() {
        let world = ReflowWorld()
        world.addColumns(4)
        world.focusColumn(3)
        let before = world.session.manager.currentWorkspace().viewportOffset
        let plan = assertEquivalent(world)
        XCTAssertEqual(plan.displays.count, 1)
        XCTAssertNotEqual(plan.displays[0].workspace.viewportOffset, before)
        XCTAssertFalse(plan.animations.isEmpty)
        XCTAssertFalse(plan.plans[0].parked.isEmpty, "off-viewport columns park")
    }

    func testCenteringMatchesLegacy() {
        let world = ReflowWorld()
        let ids = world.addColumns(3)
        world.focusColumn(1)
        assertEquivalent(world, centering: CenterRequest(mode: .always, previouslyFocused: ids[0]))
    }

    func testInstantPassPlansNoMotionAndMatchesLegacy() {
        let world = ReflowWorld()
        world.addColumns(3, placed: false)
        let plan = assertEquivalent(world, animating: false)
        XCTAssertTrue(plan.animations.isEmpty)
        XCTAssertTrue(plan.prepositions.isEmpty)
    }

    func testNeverPlacedWindowsAreReadOnceWhenAnimating() {
        let world = ReflowWorld()
        let ids = world.addColumns(2, placed: false)
        let harness = PlannerHarness(world: world)
        _ = harness.run(
            animating: true, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        )
        XCTAssertEqual(Set(world.reads), Set(ids))
        XCTAssertEqual(world.reads.count, 2)
        XCTAssertEqual(world.physicalFrames[ids[0]], world.readable[ids[0]])
        assertEquivalent(ReflowWorld().then { $0.addColumns(2, placed: false) })
    }

    func testEaseOutCurveKeepsEasedAnimations() {
        let world = ReflowWorld()
        world.addColumns(4)
        world.focusColumn(3)
        var settings = AnimationsSectionConfig()
        settings.curve = .easeOut
        assertEquivalent(world, settings: settings)
    }

    func testWorkspaceSwitchParksHiddenAndMatchesLegacy() {
        let world = ReflowWorld()
        let first = world.addColumns(2)
        world.addColumns(1, pidBase: 300, mode: .floating)
        world.session.manager.switchTo(2)
        world.syncShown()
        world.addColumns(1, pidBase: 200)
        let plan = assertEquivalent(world)
        let inactive = plan.plans.last!
        XCTAssertTrue(Set(first).isSubset(of: Set(inactive.parked.keys)), "hidden workspace parks")
        XCTAssertFalse(plan.animations.isEmpty)
    }

    func testFloatingWindowReturnsToItsFrameWhenItsWorkspaceShowsAgain() {
        let world = ReflowWorld()
        world.addColumns(1)
        let floating = world.addColumns(1, pidBase: 300, mode: .floating)[0]
        let original = world.physicalFrames[floating]!
        world.session.manager.switchTo(2)
        world.syncShown()
        world.addColumns(1, pidBase: 200)
        let harness = PlannerHarness(world: world)
        let legacy = LegacyReflowReference(world: world.copy())
        _ = harness.run(animating: true, settings: .init(), centering: .none, zoomTargets: identity)
        _ = legacy.run(animating: true, settings: .init(), centering: .none, zoomTargets: identity)
        // Parked somewhere else, then its workspace shows again.
        world.physicalFrames[floating] = CGRect(x: -2000, y: 0, width: 900, height: 700)
        legacy.world.physicalFrames[floating] = CGRect(x: -2000, y: 0, width: 900, height: 700)
        for target in [world, legacy.world] {
            target.session.manager.switchTo(1)
            target.syncShown()
        }
        let (new, _) = harness.run(animating: false, settings: .init(), centering: .none, zoomTargets: identity)
        let old = legacy.run(animating: false, settings: .init(), centering: .none, zoomTargets: identity)
        XCTAssertEqual(new, old)
        XCTAssertEqual(new.plans.last?.visible[floating], original)
    }

    func testFullscreenCoversDisplayAndMatchesLegacy() {
        let world = ReflowWorld()
        let ids = world.addColumns(3)
        world.modes[ids[2]] = .fullscreen
        let plan = assertEquivalent(world)
        XCTAssertEqual(plan.plans[0].visible.keys.sorted(), [ids[2]])
    }

    func testMinimizedHiddenWindowsAreNotParked() {
        let world = ReflowWorld()
        let first = world.addColumns(2)
        world.session.manager.switchTo(2)
        world.syncShown()
        world.addColumns(1, pidBase: 200)
        try? world.session.registry.setMinimized(true, for: first[0])
        let plan = assertEquivalent(world)
        XCTAssertNil(plan.plans.last?.parked[first[0]])
        XCTAssertNotNil(plan.plans.last?.parked[first[1]])
    }

    func testNativeZoomTargetsReplaceVisibleFramesAndMatchLegacy() {
        let world = ReflowWorld()
        let ids = world.addColumns(2)
        let zoomed = CGRect(x: 0, y: 20, width: 1800, height: 1129)
        var calls: [CGRect] = []
        let targets: (ParkingPlan, CGRect) -> [WindowID: CGRect] = { plan, viewport in
            calls.append(viewport)
            var visible = plan.visible
            if visible[ids[1]] != nil {
                visible[ids[1]] = zoomed
            }
            return visible
        }
        let plan = assertEquivalent(world, zoomTargets: targets)
        XCTAssertEqual(plan.plans[0].visible[ids[1]], zoomed)
        XCTAssertEqual(plan.hovered[ids[1]], zoomed)
        XCTAssertEqual(calls.first, world.visibleFrames[ReflowWorld.left], "judged against the usable viewport")
    }

    func testTwoDisplaysMatchLegacyWithoutHiddenWorkspaces() {
        let world = ReflowWorld(twoDisplays: true)
        world.addColumns(2, on: ReflowWorld.left)
        world.addColumns(2, pidBase: 200, on: ReflowWorld.right)
        let plan = assertEquivalent(world)
        XCTAssertEqual(plan.displays.map(\.display), [ReflowWorld.left, ReflowWorld.right])
        XCTAssertEqual(plan.displays[1].viewport.width, world.visibleFrames[ReflowWorld.right]!.width)
        XCTAssertEqual(plan.plans.count, 3, "two displays, then the inactive plan")
    }

    // MARK: Multi-display (MM-01)

    /// Two displays; the right one switched from its first workspace (two
    /// columns, physically on the right display) to an empty second one.
    private func rightDisplaySwitched() -> (ReflowWorld, [WindowID]) {
        let world = ReflowWorld(twoDisplays: true)
        world.addColumns(1, on: ReflowWorld.left)
        let hidden = world.addColumns(2, pidBase: 200, on: ReflowWorld.right)
        for (index, id) in hidden.enumerated() {
            world.physicalFrames[id] = CGRect(x: 1900 + 500 * CGFloat(index), y: 60, width: 450, height: 700)
        }
        XCTAssertTrue(world.session.manager.focus(world.session.manager.activeID(on: ReflowWorld.right)!))
        world.session.manager.switchTo(2)
        world.syncShown()
        return (world, hidden)
    }

    func testHiddenWorkspaceParksBelowTheDisplayThatOwnsIt() {
        let (world, hidden) = rightDisplaySwitched()
        let harness = PlannerHarness(world: world)
        let parked = harness.planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
            manager: world.session.manager, registry: world.session.registry
        ).parked
        for id in hidden {
            let target = try? XCTUnwrap(parked[id])
            XCTAssertEqual(target?.display, ReflowWorld.rightFrame)
            XCTAssertFalse(target.map { $0.frame.intersects(ReflowWorld.leftFrame) } ?? true)
            XCTAssertLessThanOrEqual(target?.frame.maxY ?? .infinity, ReflowWorld.rightFrame.minY + parkingSliver)
        }
    }

    func testTheDisplayThatSwitchedCarriesTheSwitchMotion() {
        let (world, hidden) = rightDisplaySwitched()
        let (_, plan) = PlannerHarness(world: world).run(
            animating: true, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        )
        for id in hidden {
            let start = world.physicalFrames[id]!
            let drop = plan.animations.first { $0.id == id }
            XCTAssertNotNil(drop, "the right display's hidden windows drop on the right display")
            XCTAssertEqual(drop?.to, slideDownFrame(drop?.from ?? start, display: ReflowWorld.rightFrame))
            XCTAssertEqual(plan.kinds[id], .workspaceSwitch)
        }
    }

    func testStandardColumnsResolveAgainstTheirOwnDisplaysWidth() {
        let world = ReflowWorld(twoDisplays: true)
        let left = world.addColumns(1, on: ReflowWorld.left)[0]
        world.addColumns(1, pidBase: 150, on: ReflowWorld.left)
        let right = world.addColumns(1, pidBase: 200, on: ReflowWorld.right)[0]
        world.addColumns(1, pidBase: 250, on: ReflowWorld.right)
        let (_, plan) = PlannerHarness(world: world).run(
            animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        )
        let layout = world.session.config.layout
        func half(_ display: DisplayID) -> CGFloat {
            proportionalColumnWidth(
                0.5, viewportWidth: world.visibleFrames[display]!.width, padding: layout.padding, gap: layout.gaps
            )
        }
        XCTAssertEqual(plan.plans[0].visible[left]?.width, half(ReflowWorld.left))
        XCTAssertEqual(plan.plans[1].visible[right]?.width, half(ReflowWorld.right))
    }

    /// MM-02 end to end: the hotkey action through `ActionApplier` and the
    /// host's shown-workspace sync.
    private func apply(_ action: HotkeyAction, in world: ReflowWorld) {
        var manager = world.session.manager
        let effect = ActionApplier.apply(action, manager: &manager, context: .init(
            registry: world.session.registry, displays: world.displays.allDisplays(),
            visibleFrames: world.visibleFrames, layout: world.session.config.layout,
            engine: { world.engine() }, modes: { world.modes }, fallbackViewport: { nil }
        ))
        world.session.manager = manager
        XCTAssertTrue(effect.syncsShownWorkspace)
        world.syncShown()
    }

    /// `apply`, then one pass.
    private func applyAndPlan(_ action: HotkeyAction, in world: ReflowWorld) -> ReflowPlan {
        apply(action, in: world)
        return PlannerHarness(world: world).run(
            animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        ).1
    }

    private func visibleFrame(_ id: WindowID, in plan: ReflowPlan) -> CGRect? {
        plan.plans.lazy.compactMap { $0.visible[id] }.first
    }

    func testAColumnMovedToTheRightDisplayIsLaidOutThere() {
        let world = ReflowWorld(twoDisplays: true)
        let ids = world.addColumns(2)
        let plan = applyAndPlan(.moveColumnToMonitor(.right), in: world)
        let moved = try? XCTUnwrap(visibleFrame(ids[1], in: plan))
        XCTAssertTrue(moved.map(ReflowWorld.rightFrame.contains) ?? false, "\(String(describing: moved))")
        let stayed = try? XCTUnwrap(visibleFrame(ids[0], in: plan))
        XCTAssertTrue(stayed.map(ReflowWorld.leftFrame.contains) ?? false, "\(String(describing: stayed))")
    }

    func testAWorkspaceMovedToTheRightDisplayShowsThereAndTheLeftOneEmpties() {
        let world = ReflowWorld(twoDisplays: true)
        let ids = world.addColumns(2)
        let plan = applyAndPlan(.moveWorkspaceToMonitor(.right), in: world)
        XCTAssertEqual(world.displays.display(ReflowWorld.right)?.workspace, world.session.manager.currentID)
        for id in ids {
            let frame = visibleFrame(id, in: plan)
            XCTAssertTrue(frame.map(ReflowWorld.rightFrame.contains) ?? false, "\(String(describing: frame))")
        }
    }

    // MARK: MM-03 floating windows follow a monitor move

    func testAFloatingWindowMovedToAnotherDisplayIsWrittenThere() {
        for action in [HotkeyAction.moveWindowToMonitor(.right), .moveColumnToMonitor(.right), .moveWorkspaceToMonitor(.right)] {
            let world = ReflowWorld(twoDisplays: true)
            world.addColumns(1)
            let floating = world.addColumns(1, pidBase: 300, mode: .floating)[0]
            let start = CGRect(x: 300, y: 200, width: 600, height: 400)
            world.physicalFrames[floating] = start
            let harness = PlannerHarness(world: world)
            harness.run(animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity)
            apply(action, in: world)
            XCTAssertEqual(world.session.manager.focusedDisplay, ReflowWorld.right, "\(action)")
            let (_, plan) = harness.run(
                animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
            )
            let expected = relocatedFloatingFrame(
                start, from: world.visibleFrames[ReflowWorld.left]!, to: world.visibleFrames[ReflowWorld.right]!
            )
            XCTAssertEqual(visibleFrame(floating, in: plan), expected, "\(action)")
            XCTAssertTrue(world.visibleFrames[ReflowWorld.right]!.contains(expected), "\(action)")
            XCTAssertEqual(expected.size, start.size)
            // Once it sits there the reflow stops writing it.
            world.physicalFrames[floating] = expected
            harness.run(animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity)
            let (_, settled) = harness.run(
                animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
            )
            XCTAssertNil(visibleFrame(floating, in: settled), "\(action)")
        }
    }

    func testAMovedFloatingWindowHidesWithItsNewDisplayAndReturnsThere() {
        let world = ReflowWorld(twoDisplays: true)
        world.addColumns(1)
        let floating = world.addColumns(1, pidBase: 300, mode: .floating)[0]
        world.physicalFrames[floating] = CGRect(x: 300, y: 200, width: 600, height: 400)
        let harness = PlannerHarness(world: world)
        harness.run(animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity)
        apply(.moveWindowToMonitor(.right), in: world)
        let landed = harness.run(
            animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        ).1.plans.last!.visible[floating]!
        world.physicalFrames[floating] = landed
        harness.run(animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity)
        // The right display switches away: the window parks under it.
        world.session.manager.switchTo(2)
        world.syncShown()
        let hidden = harness.run(
            animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        ).1.plans.last!.parked[floating]
        XCTAssertEqual(hidden?.display, ReflowWorld.rightFrame)
        world.physicalFrames[floating] = hidden?.frame
        // And back: it returns to its frame on the right display.
        world.session.manager.switchTo(1)
        world.syncShown()
        let (_, back) = harness.run(
            animating: false, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        )
        XCTAssertEqual(back.plans.last?.visible[floating], landed)
    }

    // MARK: MM-03 vertically stacked displays

    private static let lowerFrame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private static let upperFrames = [
        CGRect(x: 0, y: 1169, width: 1920, height: 1080),
        CGRect(x: 0, y: 1169, width: 1800, height: 1080),
    ]

    /// `left` is the laptop below, `right` the display above it; the upper
    /// one shows two columns physically on it.
    private func stackedWorld(upper: CGRect) -> (ReflowWorld, [WindowID]) {
        let world = ReflowWorld(frames: [(ReflowWorld.left, Self.lowerFrame), (ReflowWorld.right, upper)])
        world.addColumns(1, on: ReflowWorld.left)
        let ids = world.addColumns(2, pidBase: 200, on: ReflowWorld.right)
        for (index, id) in ids.enumerated() {
            world.physicalFrames[id] = CGRect(x: 40 + 500 * CGFloat(index), y: 1229, width: 450, height: 700)
        }
        XCTAssertTrue(world.session.manager.focus(world.session.manager.activeID(on: ReflowWorld.right)!))
        return (world, ids)
    }

    private func assertStaysOff(
        _ lower: CGRect, ids: [WindowID], plan: ReflowPlan, file: StaticString = #filePath, line: UInt = #line
    ) {
        for animation in plan.animations where ids.contains(animation.id) {
            XCTAssertFalse(
                animation.from.union(animation.to).intersects(lower),
                "flight \(animation.from) -> \(animation.to)", file: file, line: line
            )
        }
        for (id, frame) in plan.prepositions where ids.contains(id) {
            XCTAssertFalse(frame.intersects(lower), "preposition \(frame)", file: file, line: line)
        }
        for id in ids {
            if let target = plan.plans.last?.parked[id] {
                XCTAssertFalse(target.frame.intersects(lower), "parked \(target.frame)", file: file, line: line)
            }
        }
    }

    func testTheUpperDisplaysSwitchNeverSlidesOntoTheDisplayBelow() {
        for upper in Self.upperFrames {
            let (world, ids) = stackedWorld(upper: upper)
            let harness = PlannerHarness(world: world)
            world.session.manager.switchTo(2)
            world.syncShown()
            let (_, hiding) = harness.run(
                animating: true, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
            )
            for id in ids {
                XCTAssertNotNil(hiding.plans.last?.parked[id], "\(upper)")
            }
            assertStaysOff(Self.lowerFrame, ids: ids, plan: hiding)
            // They land where they were parked; then the display switches back.
            for id in ids {
                world.physicalFrames[id] = hiding.plans.last?.parked[id]?.frame
            }
            world.session.manager.switchTo(1)
            world.syncShown()
            let (_, showing) = harness.run(
                animating: true, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
            )
            assertStaysOff(Self.lowerFrame, ids: ids, plan: showing)
            for id in ids {
                let frame = visibleFrame(id, in: showing)
                XCTAssertTrue(frame.map(upper.contains) ?? false, "\(upper): \(String(describing: frame))")
            }
        }
    }

    func testTheLowerDisplayStillSlidesThroughItsFreeBottomEdge() throws {
        let world = ReflowWorld(frames: [(ReflowWorld.left, Self.lowerFrame), (ReflowWorld.right, Self.upperFrames[1])])
        world.addColumns(1, pidBase: 200, on: ReflowWorld.right)
        let ids = world.addColumns(2, on: ReflowWorld.left)
        XCTAssertTrue(world.session.manager.focus(world.session.manager.activeID(on: ReflowWorld.left)!))
        world.session.manager.switchTo(2)
        world.syncShown()
        let (_, plan) = PlannerHarness(world: world).run(
            animating: true, settings: AnimationsSectionConfig(), centering: .none, zoomTargets: identity
        )
        for id in ids {
            let drop = try XCTUnwrap(plan.animations.first { $0.id == id })
            XCTAssertEqual(drop.to, slideDownFrame(drop.from, display: Self.lowerFrame))
            XCTAssertEqual(plan.kinds[id], .workspaceSwitch)
        }
    }

    func testParkingMemoRecomputesAfterInvalidation() {
        let world = ReflowWorld()
        let first = world.addColumns(1)
        world.session.manager.switchTo(2)
        world.syncShown()
        let harness = PlannerHarness(world: world)
        let parked = harness.planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
            manager: world.session.manager, registry: world.session.registry
        ).parked
        XCTAssertNotNil(parked[first[0]])
        harness.planner.invalidateParking()
        let again = harness.planner.planInactiveWorkspaces(
            displays: world.displays.allDisplays(), visibleFrames: world.visibleFrames,
            manager: world.session.manager, registry: world.session.registry
        ).parked
        XCTAssertEqual(again, parked)
    }

    func testNoDisplaysPlansOnlyAnEmptyInactivePlan() {
        let world = ReflowWorld()
        world.displays.disconnect(ReflowWorld.left)
        let plan = assertEquivalent(world)
        XCTAssertEqual(plan.plans, [ParkingPlan(visible: [:], parked: [:])])
        XCTAssertTrue(plan.displays.isEmpty)
    }

    // MARK: Size schedules

    func testSizeSchedulesMatchTheInlineCall() {
        let id = WindowID(pid: 7, elementID: 7)
        let other = WindowID(pid: 8, elementID: 8)
        let animations = [
            WindowAnimation(id: id, from: CGRect(x: 0, y: 0, width: 400, height: 400),
                            to: CGRect(x: 0, y: 0, width: 900, height: 700), duration: 0.2),
            WindowAnimation(id: other, from: CGRect(x: 500, y: 0, width: 400, height: 400),
                            to: CGRect(x: 1000, y: 0, width: 300, height: 400), duration: 0.2)
        ]
        for resize in [ResizeMode.never, .always, .adaptive] {
            for grow in [FocusedGrowMode.start, .end] {
                var settings = AnimationsSectionConfig()
                settings.resize = resize
                settings.focusedGrow = grow
                var asked: [pid_t] = []
                let new = ReflowPlanner.sizeSchedules(
                    animations, settings: settings, canAnimateSize: { asked.append($0); return $0 == 7 }, focused: id
                )
                let old = planSizeSchedules(
                    animations, mode: resize, capablePids: [7], focused: id, focusedGrow: grow
                )
                XCTAssertEqual(new, old, "\(resize) \(grow)")
                XCTAssertEqual(asked, [7, 8], "capability asked once per animation, in order")
            }
        }
    }
}

private extension ReflowWorld {
    func then(_ body: (ReflowWorld) -> Void) -> ReflowWorld {
        body(self)
        return self
    }
}
