import CoreGraphics
import Foundation
import GioCore

/// What one reflow pass lays out, before anything is written: each display's
/// planned workspace and viewport, the visible/parked split per display (the
/// inactive-workspace plan last), the motion (animations and workspace-switch
/// prepositions) and the visible frames for hover focus.
public struct ReflowPlan: Equatable, Sendable {
    /// One display's planned state, applied by the host in this order.
    public struct DisplayOutcome: Equatable, Sendable {
        public var display: DisplayID
        public var workspace: Workspace
        public var viewport: Viewport
    }

    public var displays: [DisplayOutcome] = []
    /// Per display in display order, then the inactive-workspace plan.
    public var plans: [ParkingPlan] = []
    public var animations: [WindowAnimation] = []
    public var prepositions: [WindowID: CGRect] = [:]
    /// Visible frames of the shown displays (first display wins).
    public var hovered: [WindowID: CGRect] = [:]
}

/// The planning half of `performReflow`: lays every display out, parks the
/// windows of workspaces no display shows (NC-06) and plans the motion
/// (MO-04, NC-07). Owns the hidden-window book and the inactive parking memo
/// (PA-04). It never writes a window: the host applies the plan (reconciler,
/// motion, overlay, publication) in the same order as before. The only
/// effects it reaches are the ones planning always had: one frame read for a
/// window about to be seen that Gio never placed, and the native-zoom verdict
/// hook the host passes per display. Session queue only.
public final class ReflowPlanner: @unchecked Sendable {
    public struct Context {
        /// MO-04: every known physical frame.
        public var physicalFrames: () -> [WindowID: CGRect]
        /// One frame read of a window Gio never placed (nil when unreadable).
        public var readFrame: (WindowID) -> CGRect?
        /// Stores a learned physical frame.
        public var storePhysicalFrame: (WindowID, CGRect) -> Void

        public init(
            physicalFrames: @escaping () -> [WindowID: CGRect],
            readFrame: @escaping (WindowID) -> CGRect?,
            storePhysicalFrame: @escaping (WindowID, CGRect) -> Void
        ) {
            self.physicalFrames = physicalFrames
            self.readFrame = readFrame
            self.storePhysicalFrame = storePhysicalFrame
        }
    }

    /// One pass's inputs, read from session state at the start of the pass.
    public struct Input {
        public var displays: [DisplayState]
        public var visibleFrames: [DisplayID: CGRect]
        public var manager: WorkspaceManager
        public var modes: [WindowID: WindowMode]
        /// Rebuilt per display, as before (config reloads apply instantly).
        public var engine: () -> ScrollableLayoutEngine
        /// Applied to the current workspace's display only.
        public var centering: CenterRequest
        public var animating: Bool
        public var duration: TimeInterval
        /// NA-02: windows registered since the last pass (`WindowOpenBook`).
        public var opening: Set<WindowID>
        /// NA-02: how far below its tile a new window starts (0: no entry).
        public var openOffset: CGFloat

        public init(
            displays: [DisplayState], visibleFrames: [DisplayID: CGRect], manager: WorkspaceManager,
            modes: [WindowID: WindowMode], engine: @escaping () -> ScrollableLayoutEngine,
            centering: CenterRequest, animating: Bool, duration: TimeInterval,
            opening: Set<WindowID> = [], openOffset: CGFloat = windowOpenDefaultOffset
        ) {
            self.displays = displays
            self.visibleFrames = visibleFrames
            self.manager = manager
            self.modes = modes
            self.engine = engine
            self.centering = centering
            self.animating = animating
            self.duration = duration
            self.opening = opening
            self.openOffset = openOffset
        }
    }

    /// PA-04: parking plan of hidden windows, recomputed only when its inputs change.
    private struct InactiveParkKey: Equatable {
        var frames: [WindowID: CGRect]
        var display: CGRect
        var others: [CGRect]
    }

    private let context: Context
    private var inactiveParking = PlanMemo<InactiveParkKey, [WindowID: ParkedTarget]>()
    /// NC-06: the pre-hide frames of floating windows.
    private(set) var hiddenBook = HiddenWindowBook()

    public init(context: Context) {
        self.context = context
    }

    /// Events the parking key cannot see (display change, config reload).
    public func invalidateParking() {
        inactiveParking.invalidate()
    }

    /// Windows of workspaces no display shows hang off a corner of the first
    /// display (size kept); floating windows of shown workspaces that were
    /// hidden return to the frame they had. Minimized windows are untouched.
    public func planInactiveWorkspaces(
        displays all: [DisplayState], manager: WorkspaceManager, registry: WindowRegistry
    ) -> ParkingPlan {
        var plan = ParkingPlan(visible: [:], parked: [:])
        guard let hiddenDisplay = all.first else {
            return plan
        }
        let shown = Set(all.map(\.workspace))
        let windows = Dictionary(uniqueKeysWithValues: registry.managedWindows().map { ($0.id, $0) })
        let hidden = manager.windows(outside: shown).filter {
            windows[$0].map { !$0.isMinimized } ?? false
        }
        learnPhysicalFrames(of: hidden)
        let physical = context.physicalFrames()
        var frames: [WindowID: CGRect] = [:]
        for id in hidden {
            guard let frame = physical[id] else {
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
            (manager.workspace(id: id)?.columns ?? []).flatMap(\.windows)
        }
        // Keep the memory until the window really sits at its frame: a
        // retarget mid-flight (or an abandoned animation) must find it again.
        let floating = active.filter { windows[$0]?.mode == .floating }
        plan.visible = hiddenBook.frames(of: floating)
        for (id, frame) in plan.visible {
            if let physical = physical[id],
               abs(physical.minX - frame.minX) <= 1, abs(physical.minY - frame.minY) <= 1
            {
                _ = hiddenBook.reveal([id])
            }
        }
        return plan
    }

    /// Lay out every display. `zoomTargets` judges the native zooms that
    /// ended against a display's plan and returns its visible frames with
    /// accepted zoom frames substituted (the host's native-zoom hook, called
    /// once per laid-out display, in display order, before its motion).
    public func plan(
        _ input: Input, inactive: ParkingPlan,
        zoomTargets: (ParkingPlan, CGRect) -> [WindowID: CGRect]
    ) -> ReflowPlan {
        var result = ReflowPlan()
        // Mirrors the host's manager: the host applies `displays` in order.
        var manager = input.manager
        for (index, display) in input.displays.enumerated() {
            guard let workspace = manager.workspace(id: display.workspace) else {
                continue
            }
            let visible = input.visibleFrames[display.id] ?? display.frame
            let others = input.displays.filter { $0.id != display.id }.map(\.frame)
            guard let planned = try? planDisplayLayout(
                workspace: workspace, modes: input.modes, engine: input.engine(),
                viewport: visible, display: display.frame,
                otherDisplays: others,
                centering: display.workspace == manager.currentID ? input.centering : .none
            ) else {
                continue
            }
            var displayPlan = planned.plan
            displayPlan.visible = zoomTargets(displayPlan, visible)
            result.plans.append(displayPlan)
            result.hovered.merge(displayPlan.visible) { first, _ in first }
            if input.animating {
                // NC-07: the first display also carries the workspace switch:
                // hidden windows drop below its bottom edge, revealed ones rise.
                let carriesSwitch = index == 0
                let motionFrames = carriesSwitch
                    ? displayPlan.visible.merging(inactive.visible) { first, _ in first }
                    : displayPlan.visible
                learnPhysicalFrames(of: motionFrames.keys)
                var current = context.physicalFrames()
                // NA-02: a new window is pre-positioned just below its tile
                // (final size, one write) and rises into it with the others.
                // Only one whose frame is known: the pre-position writes from it.
                let entries = planWindowOpenEntries(
                    opening: input.opening, visible: displayPlan.visible,
                    parked: Set(displayPlan.parked.keys), modes: input.modes,
                    viewport: visible, display: display.frame, otherDisplays: others,
                    offset: input.openOffset
                ).filter { current[$0.key] != nil }
                for (id, start) in entries {
                    current[id] = start
                }
                let motion = planWorkspaceSwitchMotion(
                    current: current, visible: motionFrames,
                    parked: displayPlan.parked, hidden: carriesSwitch ? inactive.parked : [:],
                    viewport: visible, display: display.frame, duration: input.duration
                )
                result.animations += motion.animations
                result.prepositions.merge(motion.prepositions) { _, new in new }
                result.prepositions.merge(entries) { _, new in new }
            }
            // Logical state moves at once; only the physical writes animate.
            manager.update(planned.workspace)
            result.displays.append(.init(
                display: display.id, workspace: planned.workspace,
                viewport: Viewport(offset: planned.layout.viewportOffset, width: visible.width)
            ))
        }
        result.plans.append(inactive)
        return result
    }

    /// NF-04: the spring curve replaces the eased timing.
    public static func applyingCurve(
        _ animations: [WindowAnimation], settings: AnimationsSectionConfig
    ) -> [WindowAnimation] {
        settings.curve == .spring ? animations.map { $0.springing(settings.spring) } : animations
    }

    /// PA-06 / FI-03: size schedules. Growing windows follow the flight when
    /// their app keeps up; the focused window that grows gets its final size
    /// in the first frame (`focusedGrow`).
    public static func sizeSchedules(
        _ animations: [WindowAnimation], settings: AnimationsSectionConfig,
        canAnimateSize: (pid_t) -> Bool, focused: WindowID?
    ) -> [WindowAnimation] {
        let capablePids = Set(animations.map(\.id.pid).filter { canAnimateSize($0) })
        return planSizeSchedules(
            animations, mode: settings.resize, capablePids: capablePids,
            focused: focused, focusedGrow: settings.focusedGrow
        )
    }

    /// Windows about to be seen but never placed by us (new ones) have no
    /// known physical frame; one read each lets them slide in.
    private func learnPhysicalFrames(of ids: some Sequence<WindowID>) {
        for id in ids where context.physicalFrames()[id] == nil {
            if let frame = context.readFrame(id) {
                context.storePhysicalFrame(id, frame)
            }
        }
    }
}
