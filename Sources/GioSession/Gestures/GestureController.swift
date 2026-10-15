import CoreGraphics
import Foundation
import GioCore

/// TG-03: what a released scroll hands the session: the swiped workspace's
/// windows, the velocity they move with (points per second along x) and
/// whether the settle focused another window (State is already committed).
public struct GestureRelease: Equatable, Sendable {
    public var windows: Set<WindowID>
    public var velocity: CGFloat
    public var focusChanged: Bool

    public init(windows: Set<WindowID>, velocity: CGFloat, focusChanged: Bool) {
        self.windows = windows
        self.velocity = velocity
        self.focusChanged = focusChanged
    }
}

/// TG-03: why a scroll ended without a settle.
public enum GestureAbandon: String, Equatable, Sendable {
    /// A mouse button went down (a click, or three-finger drag).
    case mouse
    /// A finger joined the swipe.
    case cancelled
}

/// TG-03: trackpad gestures on the session queue. Contact frames arrive from
/// `TouchFrameMailbox`; the recognizer turns them into swipes.
///
/// - Scroll: while the fingers are down the strip of the display under them
///   follows the fingers. Each batch of frames lays the strip out at the
///   gesture's offset (no reveal) and hands the frames to the reconciler's
///   motion sink: every changed window on its app's Accessibility motion
///   lane (latest frame wins). State does not move meanwhile. On release
///   the snap is committed to State (offset and focus) and the session runs
///   an animated pass whose springs start with the release velocity (on the
///   snapshot overlay when it can fly, else on the motion player).
/// - An extra finger or a mouse button abandons the scroll: State is
///   untouched and the session lays the strip out as State says.
/// - Vertical swipes switch workspace (`focus-workspace-up/down`) or toggle
///   the overview.
public final class GestureController: @unchecked Sendable {
    public struct Context {
        public var settings: () -> GesturesSectionConfig
        public var isMouseDown: () -> Bool
        /// The strip under the pointer (else the focused display's).
        public var surface: () -> GestureSurface?
        public var physicalFrames: () -> [WindowID: CGRect]
        /// The reconciler (invariant 3); nil before the first pass.
        public var sink: () -> MotionFrameSink?
        public var updateManager: ((inout WorkspaceManager) -> Void) -> Void
        /// The fingers took the strip: stop the running motion and overlay.
        public var beginTracking: () -> Void
        /// A frame a window is being moved to (physical frame, echo record).
        public var recordSampled: (WindowID, CGRect, TimeInterval) -> Void
        /// A window joined the gesture: its frame is unverified from now on.
        public var markUnverified: (WindowID) -> Void
        public var focusedWindow: () -> WindowID?
        public var publishFocusRing: () -> Void
        /// Released: State holds the snap; run the settle pass.
        public var settle: (GestureRelease) -> Void
        /// Abandoned: lay the strip out from State again.
        public var abandon: (GestureAbandon) -> Void
        public var perform: (HotkeyAction) -> Void
        public var toggleOverview: () -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            settings: @escaping () -> GesturesSectionConfig, isMouseDown: @escaping () -> Bool,
            surface: @escaping () -> GestureSurface?, physicalFrames: @escaping () -> [WindowID: CGRect],
            sink: @escaping () -> MotionFrameSink?,
            updateManager: @escaping ((inout WorkspaceManager) -> Void) -> Void,
            beginTracking: @escaping () -> Void,
            recordSampled: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            markUnverified: @escaping (WindowID) -> Void, focusedWindow: @escaping () -> WindowID?,
            publishFocusRing: @escaping () -> Void, settle: @escaping (GestureRelease) -> Void,
            abandon: @escaping (GestureAbandon) -> Void, perform: @escaping (HotkeyAction) -> Void,
            toggleOverview: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.settings = settings
            self.isMouseDown = isMouseDown
            self.surface = surface
            self.physicalFrames = physicalFrames
            self.sink = sink
            self.updateManager = updateManager
            self.beginTracking = beginTracking
            self.recordSampled = recordSampled
            self.markUnverified = markUnverified
            self.focusedWindow = focusedWindow
            self.publishFocusRing = publishFocusRing
            self.settle = settle
            self.abandon = abandon
            self.perform = perform
            self.toggleOverview = toggleOverview
            self.log = log
            self.now = now
        }
    }

    /// One scroll in progress.
    private final class Scroll {
        let surface: GestureSurface
        let strip: GestureStrip
        var tracker: GestureScrollTracker
        let pump: GestureFramePump
        let windows: Set<WindowID>
        var touched: Set<WindowID> = []
        var moved = false

        init(surface: GestureSurface, strip: GestureStrip, tracker: GestureScrollTracker, pump: GestureFramePump, windows: Set<WindowID>) {
            self.surface = surface
            self.strip = strip
            self.tracker = tracker
            self.pump = pump
            self.windows = windows
        }
    }

    private let context: Context
    private var recognizer = GestureRecognizer(settings: GesturesSectionConfig().recognizerSettings)
    private var scroll: Scroll?
    private var sawFrames = false

    public init(context: Context) {
        self.context = context
    }

    /// The fingers own a strip: passes wait for the release.
    public var isTracking: Bool {
        scroll != nil
    }

    /// Apps whose moved events are the gesture's own writes.
    public var animatingPids: Set<pid_t> {
        scroll?.pump.pids ?? []
    }

    /// Session queue: one mailbox drain.
    public func deliver(_ frames: [TouchFrame]) {
        let settings = context.settings()
        recognizer.settings = settings.recognizerSettings
        if !sawFrames, let first = frames.first {
            sawFrames = true
            context.log(.info, "gestures first contact frame fingers=\(first.contacts.count)")
        }
        if scroll != nil, context.isMouseDown() {
            abandon(.mouse)
        }
        for frame in frames {
            for event in recognizer.feed(frame) {
                handle(event, settings: settings)
            }
        }
        render()
    }

    private func handle(_ event: TrackpadGestureEvent, settings: GesturesSectionConfig) {
        switch event {
        case .scrollBegan(let count):
            begin(fingers: count)
        case .scrollChanged(let dx):
            guard let scroll else {
                return
            }
            scroll.tracker.apply(gestureOffsetDelta(
                fingerDX: dx, viewportWidth: scroll.strip.viewportWidth,
                sensitivity: settings.scrollSensitivity, natural: settings.natural
            ))
            scroll.moved = true
        case .scrollEnded(let velocity):
            release(fingerVelocity: velocity, settings: settings)
        case .scrollCancelled:
            if scroll != nil {
                abandon(.cancelled)
            }
        case .verticalSwipe(let count, let direction):
            if settings.workspaceSwipe, count == settings.workspaceFingers {
                let action = workspaceSwipeAction(direction, natural: settings.natural)
                context.log(.info, "gesture swipe fingers=\(count) direction=\(direction.rawValue) action=\(action)")
                context.perform(action)
            } else if settings.overview, count == settings.overviewFingers, direction == .up {
                context.log(.info, "gesture swipe fingers=\(count) direction=up action=toggle-overview")
                context.toggleOverview()
            }
        }
    }

    private func begin(fingers: Int) {
        guard !context.isMouseDown() else {
            context.log(.debug, "gesture scroll ignored fingers=\(fingers) reason=mouse")
            return
        }
        guard let surface = context.surface(), let strip = gestureStrip(surface), let sink = context.sink() else {
            context.log(.debug, "gesture scroll ignored fingers=\(fingers) reason=no-strip")
            return
        }
        context.beginTracking()
        let physical = context.physicalFrames()
        let committed = gestureFrames(surface, offset: strip.committedOffset)
        let base = gestureVisualOffset(
            committed: strip.committedOffset, visible: committed?.visible ?? [:], physical: physical,
            prefer: surface.workspace.focusedWindow
        )
        let windows = Set(tilingWorkspace(from: surface.workspace, modes: surface.modes).columns.flatMap(\.windows))
        var start: [WindowID: CGRect] = [:]
        for id in windows {
            start[id] = physical[id] ?? committed?.visible[id] ?? committed?.parked[id]?.frame
        }
        scroll = Scroll(
            surface: surface, strip: strip, tracker: GestureScrollTracker(base: base, maxOffset: strip.maxOffset),
            pump: GestureFramePump(sink: sink, start: start), windows: windows
        )
        context.log(
            .info,
            "gesture scroll begin display=\(surface.display.rawValue) fingers=\(fingers) offset=\(Int(base.rounded())) columns=\(strip.columns.count)"
        )
    }

    /// Writes the strip at the gesture's offset, once per drain.
    private func render() {
        guard let scroll, scroll.moved else {
            return
        }
        scroll.moved = false
        guard let plan = gestureFrames(scroll.surface, offset: scroll.tracker.offset) else {
            return
        }
        var targets = plan.visible
        for (id, parked) in plan.parked {
            targets[id] = parked.frame
        }
        let written = scroll.pump.pump(targets)
        let now = context.now()
        for id in written.keys.sorted() {
            if scroll.touched.insert(id).inserted {
                context.markUnverified(id)
            }
            context.recordSampled(id, written[id]!, now)
        }
        if let focused = context.focusedWindow(), written[focused] != nil {
            context.publishFocusRing()
        }
    }

    private func release(fingerVelocity: Double, settings: GesturesSectionConfig) {
        guard let scroll else {
            return
        }
        render()
        let offsetVelocity = gestureOffsetDelta(
            fingerDX: fingerVelocity, viewportWidth: scroll.strip.viewportWidth,
            sensitivity: settings.scrollSensitivity, natural: settings.natural
        )
        self.scroll = nil
        guard let snap = snapGestureScroll(scroll.strip, offset: scroll.tracker.offset, velocity: offsetVelocity) else {
            context.abandon(.cancelled)
            return
        }
        var focusChanged = false
        context.updateManager { manager in
            focusChanged = commitGestureScroll(
                &manager, display: scroll.surface.display, workspace: scroll.surface.workspace.id,
                strip: scroll.strip, snap: snap
            )
        }
        context.log(
            .info,
            "gesture scroll end offset=\(Int(scroll.tracker.offset.rounded())) snap=\(Int(snap.offset.rounded())) column=\(snap.column) velocity=\(Int((-offsetVelocity).rounded())) focusChanged=\(focusChanged)"
        )
        context.settle(GestureRelease(windows: scroll.windows, velocity: -offsetVelocity, focusChanged: focusChanged))
    }

    private func abandon(_ reason: GestureAbandon) {
        scroll = nil
        context.log(.info, "gesture scroll abandoned reason=\(reason.rawValue)")
        context.abandon(reason)
    }
}
