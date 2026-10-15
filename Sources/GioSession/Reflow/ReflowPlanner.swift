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
    /// NA-04: the animation kind of every planned flight.
    public var kinds: [WindowID: AnimationKind] = [:]
    /// PF-02: the pre-positions that are NA-02 entries (new windows): their
    /// writes never wait for an in-flight motion.
    public var entries: Set<WindowID> = []
    /// MM-04: windows parking on the far side of their display (the near
    /// side is another display) or coming back from there: no flight across
    /// the display; they are pre-positioned at their target instead. MM-10:
    /// the snapshot overlay slides their layers along `JumpPath` (out by,
    /// or in from, the shared edge, clipped by their display's overlay).
    public var jumps: [WindowID: JumpPath] = [:]
}

/// MM-10: the layer path of a window that jumps (`ReflowPlan.jumps`): its
/// real window is written once at the motion start, while its snapshot
/// layer slides `from` -> `to` on `display`'s overlay. Leaving, `to` is its
/// strip frame pushed just past the display edge; coming back, `from` is.
public struct JumpPath: Equatable, Sendable {
    public let from: CGRect
    public let to: CGRect
    public let display: CGRect

    public init(from: CGRect, to: CGRect, display: CGRect) {
        self.from = from
        self.to = to
        self.display = display
    }
}

/// MM-10: `frame` moved along x until it is off `display` on the side of
/// its centre (unchanged when it already is).
func pushedOffDisplay(_ frame: CGRect, display: CGRect) -> CGRect {
    guard frame.intersects(display) else {
        return frame
    }
    let x = frame.midX < display.midX ? display.minX - frame.width : display.maxX
    return CGRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
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
        /// NA-04: what triggered the pass (picks the flights' animation kind).
        public var cause: MotionCause

        public init(
            displays: [DisplayState], visibleFrames: [DisplayID: CGRect], manager: WorkspaceManager,
            modes: [WindowID: WindowMode], engine: @escaping () -> ScrollableLayoutEngine,
            centering: CenterRequest, animating: Bool, duration: TimeInterval,
            opening: Set<WindowID> = [], openOffset: CGFloat = windowOpenDefaultOffset,
            cause: MotionCause = .passive
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
            self.cause = cause
        }
    }

    /// PA-04: parking plan of one display's hidden windows, recomputed only
    /// when its inputs change.
    private struct InactiveParkKey: Equatable {
        var frames: [WindowID: CGRect]
        var display: CGRect
        var others: [CGRect]
    }

    private let context: Context
    /// MM-01: one memo per display that hides windows.
    private var inactiveParking: [DisplayID: PlanMemo<InactiveParkKey, [WindowID: ParkedTarget]>] = [:]
    /// NC-06: the pre-hide frames of floating windows; MM-03: also the frame
    /// a floating window moves to when its workspace changed display.
    private(set) var hiddenBook = HiddenWindowBook()
    /// MM-03: the connected display whose stack held each floating window
    /// at the last pass.
    private var floatingDisplays: [WindowID: DisplayID] = [:]
    /// MM-04: the windows the last pass parked on the far side of their
    /// display (`ParkedTarget.farSide`): coming back, they jump too.
    private var farParked: Set<WindowID> = []

    public init(context: Context) {
        self.context = context
    }

    /// Events the parking key cannot see (display change, config reload).
    public func invalidateParking() {
        inactiveParking.removeAll()
    }

    /// Windows of workspaces no display shows hang off a corner of the
    /// display whose stack holds them (MM-01; a stack without a connected
    /// display uses the first one), size kept, never on another display
    /// (MM-03); floating windows of shown workspaces that were hidden return
    /// to the frame they had, and floating windows whose workspace now lives
    /// on another display (move-column/window/workspace-to-monitor) are
    /// written onto it (MM-03). Minimized windows are untouched.
    public func planInactiveWorkspaces(
        displays all: [DisplayState], visibleFrames: [DisplayID: CGRect],
        manager: WorkspaceManager, registry: WindowRegistry
    ) -> ParkingPlan {
        var plan = ParkingPlan(visible: [:], parked: [:])
        guard let fallback = all.first else {
            return plan
        }
        let shown = Set(all.map(\.workspace))
        let windows = Dictionary(uniqueKeysWithValues: registry.managedWindows().map { ($0.id, $0) })
        // FI-10: a window that yielded to its app is never written: not
        // parked, not restored, not moved with its workspace.
        _ = hiddenBook.reveal(windows.values.filter(\.isAppControlled).map(\.id))
        let hidden = manager.windows(outside: shown).filter {
            windows[$0].map { !$0.isMinimized && !$0.isAppControlled } ?? false
        }
        let connected = Set(all.map(\.id))
        var owners: [WindowID: DisplayID] = [:]
        for display in manager.displayIDs {
            let owner = connected.contains(display) ? display : fallback.id
            for workspace in manager.stack(on: display) where !shown.contains(workspace.id) {
                for id in workspace.columns.flatMap(\.windows) {
                    owners[id] = owner
                }
            }
        }
        learnPhysicalFrames(of: hidden)
        let physical = context.physicalFrames()
        var frames: [DisplayID: [WindowID: CGRect]] = [:]
        for id in hidden {
            guard let frame = physical[id] else {
                continue
            }
            frames[owners[id] ?? fallback.id, default: [:]][id] = frame
            if windows[id]?.mode == .floating {
                hiddenBook.hide(id, from: frame)
            }
        }
        relocateFloatingWindows(
            displays: all, visibleFrames: visibleFrames, manager: manager, windows: windows, physical: physical
        )
        for display in all {
            let own = frames[display.id] ?? [:]
            let others = all.filter { $0.id != display.id }.map(\.frame)
            var memo = inactiveParking[display.id] ?? PlanMemo()
            let parked = memo.value(for: InactiveParkKey(frames: own, display: display.frame, others: others)) {
                planHiddenWindows(frames: own, display: display.frame, otherDisplays: others)
            }
            inactiveParking[display.id] = memo
            plan.parked.merge(parked) { _, new in new }
        }
        let active = shown.flatMap { id in
            (manager.workspace(id: id)?.columns ?? []).flatMap(\.windows)
        }
        // Keep the memory until the window really sits at its frame, or a
        // settled pass attempted it (`restoreSettled`): a retarget mid-flight
        // (or an abandoned animation) must find it again.
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

    /// FI-09: a settled pass wrote these frames (`visible`), minus the
    /// windows it deferred. A floating window written at its remembered
    /// frame was restored, whether the write landed or not: an app that
    /// re-centres its dialog would otherwise be rewritten by every later
    /// reflow, since a failed write leaves no physical frame to match.
    public func restoreSettled(visible: [WindowID: CGRect], deferred: some Sequence<WindowID>) {
        let deferred = Set(deferred)
        let attempted = hiddenBook.frames(of: visible.keys).filter { id, frame in
            visible[id] == frame && !deferred.contains(id)
        }
        _ = hiddenBook.reveal(attempted.keys)
    }

    /// MM-03: a floating window follows its workspace to another display:
    /// the book takes its frame translated onto the new display, which the
    /// shown-floating path below writes (or keeps for when it is shown).
    private func relocateFloatingWindows(
        displays all: [DisplayState], visibleFrames: [DisplayID: CGRect], manager: WorkspaceManager,
        windows: [WindowID: ManagedWindow], physical: [WindowID: CGRect]
    ) {
        var current: [WindowID: DisplayID] = [:]
        var visible: [DisplayID: CGRect] = [:]
        for display in all {
            visible[display.id] = visibleFrames[display.id] ?? display.frame
            for workspace in manager.stack(on: display.id) {
                for id in workspace.columns.flatMap(\.windows) where windows[id]?.mode == .floating {
                    current[id] = display.id
                }
            }
        }
        let movable = current.keys.filter { windows[$0].map { !$0.isMinimized && !$0.isAppControlled } ?? false }
        var frames: [WindowID: CGRect] = [:]
        for id in movable {
            frames[id] = physical[id]
        }
        frames.merge(hiddenBook.frames(of: movable)) { _, remembered in remembered }
        let moves = planFloatingRelocations(
            frames: frames, previous: floatingDisplays, current: current, visibleFrames: visible
        )
        for (id, frame) in moves {
            hiddenBook.move(id, to: frame)
        }
        floatingDisplays = current
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
        var farParkedNow: Set<WindowID> = []
        defer { farParked = farParkedNow }
        // Mirrors the host's manager: the host applies `displays` in order.
        var manager = input.manager
        for display in input.displays {
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
            let farHere = Set(displayPlan.parked.filter(\.value.farSide).keys)
            farParkedNow.formUnion(farHere)
            result.hovered.merge(displayPlan.visible) { first, _ in first }
            if input.animating {
                // NC-07 / MM-01: each display carries its own part of a
                // workspace switch: the hidden windows parked below it drop
                // under its bottom edge, the floating windows it shows again
                // rise. A display whose workspace did not change has none.
                let shownHere = Set(workspace.columns.flatMap(\.windows))
                let hiddenHere = inactive.parked.filter { $0.value.display == display.frame }
                let revealedHere = inactive.visible.filter { shownHere.contains($0.key) }
                let motionFrames = displayPlan.visible.merging(revealedHere) { first, _ in first }
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
                var motion = planWorkspaceSwitchMotion(
                    current: current, visible: motionFrames,
                    parked: displayPlan.parked, hidden: hiddenHere,
                    viewport: visible, display: display.frame, otherDisplays: others,
                    duration: input.duration
                )
                // MM-04: a far-side park (its near edge is another display)
                // or a return from one would fly across the whole display:
                // it jumps to its target when the motion starts instead.
                let jumps = jumpingWindows(
                    farParked: farHere, returning: Set(displayPlan.visible.keys).intersection(farParked),
                    targets: displayPlan, current: current
                )
                motion.animations.removeAll { jumps[$0.id] != nil }
                for id in jumps.keys {
                    motion.prepositions.removeValue(forKey: id)
                }
                result.animations += motion.animations
                result.prepositions.merge(motion.prepositions) { _, new in new }
                result.prepositions.merge(jumps) { _, new in new }
                // MM-10: their layers slide by the shared edge: out to the
                // strip frame (pushed past the edge), or in from where the
                // strip had them before this scroll.
                let scrolled = planned.layout.viewportOffset - workspace.viewportOffset
                for (id, target) in jumps {
                    let path = farHere.contains(id)
                        ? JumpPath(
                            from: current[id] ?? target,
                            to: pushedOffDisplay(planned.layout.frames[id] ?? target, display: display.frame),
                            display: display.frame
                        )
                        : JumpPath(
                            from: pushedOffDisplay(target.offsetBy(dx: scrolled, dy: 0), display: display.frame),
                            to: target,
                            display: display.frame
                        )
                    result.jumps[id] = path
                }
                result.prepositions.merge(entries) { _, new in new }
                result.entries.formUnion(entries.keys)
                // NA-04: risers (pre-positioned below) and hidden windows that
                // drop are the workspace switch; entries are window-open.
                var switching = Set(motion.prepositions.keys)
                switching.formUnion(motion.animations.map(\.id).filter { hiddenHere[$0] != nil })
                result.kinds.merge(classifyAnimationKinds(
                    motion.animations.map(\.id), cause: input.cause,
                    opening: Set(entries.keys), switching: switching
                )) { _, new in new }
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

    /// MM-04: the far-side parks and the windows returning from one, with
    /// their target, when they are not there yet.
    private func jumpingWindows(
        farParked: Set<WindowID>, returning: Set<WindowID>, targets: ParkingPlan, current: [WindowID: CGRect]
    ) -> [WindowID: CGRect] {
        var jumps: [WindowID: CGRect] = [:]
        for id in farParked {
            jumps[id] = targets.parked[id]?.frame
        }
        for id in returning {
            jumps[id] = targets.visible[id]
        }
        return jumps.filter { current[$0.key] != $0.value }
    }

    /// NF-04: the spring curve replaces the eased timing.
    public static func applyingCurve(
        _ animations: [WindowAnimation], settings: AnimationsSectionConfig
    ) -> [WindowAnimation] {
        settings.curve == .spring ? animations.map { $0.springing(settings.spring) } : animations
    }

    /// NA-04: each flight takes the settings of its kind (`kinds`, else
    /// `fallback`, the pass's kind): its spring, or its ease-out duration. A
    /// kind that is off inside an animated pass lands on the next frame
    /// instead of waiting for the final pass behind the others.
    public static func applyingAnimationSettings(
        _ animations: [WindowAnimation], settings: AnimationsSectionConfig,
        kinds: [WindowID: AnimationKind], fallback: AnimationKind
    ) -> [WindowAnimation] {
        animations.map { animation in
            let resolved = settings.resolved(kinds[animation.id] ?? fallback)
            guard resolved.isActive else {
                var jump = WindowAnimation(
                    id: animation.id, from: animation.from, to: animation.to,
                    duration: disabledKindDuration, easing: .linear
                )
                jump.sizeSchedule = animation.sizeSchedule
                return jump
            }
            switch resolved.curve {
            case .spring:
                return animation.springing(resolved.spring)
            case .easeOut:
                var eased = animation
                eased.duration = resolved.duration
                return eased
            }
        }
    }

    /// A disabled kind's flight: done by the second tick.
    static let disabledKindDuration: TimeInterval = 0.001

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

private extension ManagedWindow {
    /// FI-10: floating because its app kept restoring its own frame.
    var isAppControlled: Bool {
        floatReason == .appControlled
    }
}
