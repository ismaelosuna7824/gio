import CoreGraphics
import GioCore

/// NF-06: the dim overlay. Every ring publication calls `update()`: it
/// hides at once while anything moves, otherwise asks for one coalesced
/// recompute (one on-screen WindowServer query, never on main, never an AX
/// call). No timer runs at rest. Session queue only; `deliver` runs on main.
public final class FocusDimPublisher: @unchecked Sendable {
    public struct Context {
        public var session: () -> CommandSession
        public var physicalFrame: (WindowID) -> CGRect?
        public var displays: () -> [DisplayState]
        public var isMotionActive: () -> Bool
        public var isFlightActive: () -> Bool
        /// A native zoom is animating, awaiting its verdict or being verified.
        public var isNativeZoomActive: () -> Bool
        public var isMouseDown: () -> Bool
        public var isShuttingDown: () -> Bool
        /// The on-screen z-order (Cocoa coordinates), queried once per recompute.
        public var frontToBack: () -> [ServerWindow]
        public var mainHop: MainHop
        public var deliver: (FocusDimState) -> Void

        public init(
            session: @escaping () -> CommandSession, physicalFrame: @escaping (WindowID) -> CGRect?,
            displays: @escaping () -> [DisplayState], isMotionActive: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isNativeZoomActive: @escaping () -> Bool,
            isMouseDown: @escaping () -> Bool, isShuttingDown: @escaping () -> Bool,
            frontToBack: @escaping () -> [ServerWindow], mainHop: @escaping MainHop,
            deliver: @escaping (FocusDimState) -> Void
        ) {
            self.session = session
            self.physicalFrame = physicalFrame
            self.displays = displays
            self.isMotionActive = isMotionActive
            self.isFlightActive = isFlightActive
            self.isNativeZoomActive = isNativeZoomActive
            self.isMouseDown = isMouseDown
            self.isShuttingDown = isShuttingDown
            self.frontToBack = frontToBack
            self.mainHop = mainHop
            self.deliver = deliver
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private let mailbox = LatestValueMailbox<FocusDimState>()
    private var recomputeScheduled = false
    /// Set by a non-echo frame event, cleared by the next reflow.
    public private(set) var isDragHeld = false

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    public func activity() -> FocusDimActivity {
        FocusDimActivity(
            motion: context.isMotionActive(), flight: context.isFlightActive(),
            nativeZoom: context.isNativeZoomActive(), mouseDown: context.isMouseDown(), dragHeld: isDragHeld
        )
    }

    public func update() {
        switch focusDimDecision(indicator: context.session().config.focus.indicator, activity: activity()) {
        case .hide(let reason):
            post(.hidden(reason))
        case .compute, .retryAfterRelease:
            scheduleRecompute(after: 0.05)
        }
    }

    /// The window moved on its own (drag, app resize): the dim comes down and
    /// returns after the snap-back reflow.
    public func holdForDrag() {
        isDragHeld = true
        post(.hidden(.drag))
    }

    /// The snap-back reflow after a drag releases the hold.
    public func releaseDragHold() {
        isDragHeld = false
    }

    public func post(_ state: FocusDimState) {
        guard mailbox.post(state) else {
            return
        }
        context.mainHop { [weak self] in
            guard let self, let next = self.mailbox.take() else {
                return
            }
            self.context.deliver(next)
        }
    }

    private func scheduleRecompute(after delay: Double) {
        guard !recomputeScheduled else {
            return
        }
        recomputeScheduled = true
        scheduler.asyncAfter(delay) { [weak self] in
            guard let self else {
                return
            }
            self.recomputeScheduled = false
            self.recompute()
        }
    }

    /// Re-checks the timing rule (a motion may have started since), then
    /// queries the WindowServer once.
    private func recompute() {
        guard !context.isShuttingDown() else {
            return
        }
        switch focusDimDecision(indicator: context.session().config.focus.indicator, activity: activity()) {
        case .hide(let reason):
            post(.hidden(reason))
        case .retryAfterRelease:
            // Only while a button is held: compute after release.
            scheduleRecompute(after: 0.05)
        case .compute:
            post(snapshot())
        }
    }

    /// Visible tiled windows of every shown workspace (Gio's physical frames)
    /// against the on-screen z-order. Only the current workspace's focus is lit.
    public func snapshot() -> FocusDimState {
        let session = context.session()
        guard let focusedID = session.manager.currentWorkspace().focusedWindow,
              let focusedFrame = context.physicalFrame(focusedID),
              session.registry.find(focusedID)?.isMinimized == false
        else {
            return .hidden(.noFocus)
        }
        var windows: [DimWindow] = []
        for display in context.displays() {
            guard let workspace = session.manager.workspace(id: display.workspace) else {
                continue
            }
            for id in workspace.columns.flatMap(\.windows) where id != focusedID {
                guard let record = session.registry.find(id), record.mode == .tiled, !record.isMinimized,
                      let frame = context.physicalFrame(id)
                else {
                    continue
                }
                windows.append(DimWindow(pid: id.pid, frame: frame))
            }
        }
        let regions = focusDimRegions(
            focused: DimWindow(pid: focusedID.pid, frame: focusedFrame), windows: windows,
            frontToBack: context.frontToBack(),
            displays: context.displays().map(\.frame)
        )
        return regions.isEmpty ? .hidden(.noFocus) : .shown(regions: regions, strength: session.config.focus.dimStrength)
    }
}
