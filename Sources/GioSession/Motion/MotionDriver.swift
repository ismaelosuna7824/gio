import CoreGraphics
import Foundation
import GioCore

/// MO-04: the AX motion. Owns the frame player, its display-rate strict
/// timer, the pids whose moved/resized events are our own writes (PA-04),
/// the latest flight's animations (FI-03 grows measured at the final pass)
/// and the resize-latency probes. Session queue only.
///
/// `tick()` is the hot path, run at display rate: it samples the player and
/// reports each sampled frame through a stored closure. No per-tick
/// allocation beyond the player's own sample, no existentials, no tasks.
public final class MotionDriver: @unchecked Sendable {
    public struct Context {
        public var isShuttingDown: () -> Bool
        public var isMouseDown: () -> Bool
        /// A mouse-abandoned motion: the next pass is written without motion.
        public var armInstantPlacementForMouse: () -> Void
        /// The deferred-aware reflow entry (waits for the mouse button).
        public var reflowAll: () -> Void
        /// FI-06: true when actions since the last tick asked for a retarget.
        public var takeCoalescedReflow: () -> Bool
        public var resetCoalescer: () -> Void
        /// One retargeting pass (animated).
        public var performReflow: () -> Void
        /// The motion ended: the final exact pass (instant).
        public var finalPass: () -> Void
        /// A frame the window is being moved to (physical frame + echo record).
        public var recordSampled: (WindowID, CGRect, TimeInterval) -> Void
        /// A preposition landed (physical frame, trust invalidated, echo record).
        public var recordPreposition: (WindowID, CGRect, TimeInterval) -> Void
        /// A window joined the motion: its frame is unverified from now on
        /// (trust invalidated, render check candidate).
        public var markUnverified: (WindowID) -> Void
        public var focusedWindow: () -> WindowID?
        public var publishFocusRing: () -> Void
        public var learnResizeCapability: (MotionSummary) -> Void
        public var physicalFrame: (WindowID) -> CGRect?
        /// PA-03: the screens' refresh rates, read when a motion starts.
        public var displayRefreshes: () -> [DisplayRefresh]
        /// App names for the player's summary (resolved once per slowest pid).
        public var playerAppName: @Sendable (pid_t) -> String?
        /// The player's clock.
        public var playerClock: ReflowClock
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            isShuttingDown: @escaping () -> Bool, isMouseDown: @escaping () -> Bool,
            armInstantPlacementForMouse: @escaping () -> Void, reflowAll: @escaping () -> Void,
            takeCoalescedReflow: @escaping () -> Bool, resetCoalescer: @escaping () -> Void,
            performReflow: @escaping () -> Void, finalPass: @escaping () -> Void,
            recordSampled: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            recordPreposition: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            markUnverified: @escaping (WindowID) -> Void,
            focusedWindow: @escaping () -> WindowID?, publishFocusRing: @escaping () -> Void,
            learnResizeCapability: @escaping (MotionSummary) -> Void,
            physicalFrame: @escaping (WindowID) -> CGRect?,
            displayRefreshes: @escaping () -> [DisplayRefresh],
            playerAppName: @escaping @Sendable (pid_t) -> String?,
            playerClock: @escaping ReflowClock = systemReflowClock,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.isShuttingDown = isShuttingDown
            self.isMouseDown = isMouseDown
            self.armInstantPlacementForMouse = armInstantPlacementForMouse
            self.reflowAll = reflowAll
            self.takeCoalescedReflow = takeCoalescedReflow
            self.resetCoalescer = resetCoalescer
            self.performReflow = performReflow
            self.finalPass = finalPass
            self.recordSampled = recordSampled
            self.recordPreposition = recordPreposition
            self.markUnverified = markUnverified
            self.focusedWindow = focusedWindow
            self.publishFocusRing = publishFocusRing
            self.learnResizeCapability = learnResizeCapability
            self.physicalFrame = physicalFrame
            self.displayRefreshes = displayRefreshes
            self.playerAppName = playerAppName
            self.playerClock = playerClock
            self.log = log
            self.now = now
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private let resizeProbes: ResizeProbeRunner
    private var player: MotionPlayer?
    private var timer: SessionTimer?
    /// The running timer's interval (fixed for the motion, PA-03).
    private var timerInterval: TimeInterval?
    /// Diagnostics: the latest flight's animations (to find the FI-03 grows
    /// at the final pass).
    private var lastAnimations: [WindowAnimation] = []
    /// PA-04: pids with windows in the running motion; their moved/resized
    /// events are our own writes and are dropped before any lookup.
    public private(set) var animatingPids: Set<pid_t> = []

    public init(context: Context, resizeProbes: ResizeProbeRunner, scheduler: SessionScheduler) {
        self.context = context
        self.resizeProbes = resizeProbes
        self.scheduler = scheduler
    }

    /// A motion is running.
    public var isActive: Bool {
        player?.isActive == true
    }

    /// Place hidden incoming windows directly below their target before the
    /// player starts (off-screen, so the jump is invisible). `write` performs
    /// the prepositions and returns the windows it wrote.
    public func applyPrepositions(_ frames: [WindowID: CGRect], write: ([WindowID: CGRect]) -> [WindowID]) {
        let written = write(frames)
        for id in written {
            guard let frame = frames[id] else {
                continue
            }
            context.recordPreposition(id, frame, context.now())
        }
    }

    /// Begin, or retarget the running motion. The player is created once,
    /// with the first sink it is given. The first tick runs from the
    /// scheduler, never inside this call (PF-Q: the host's motion-start
    /// focus no longer runs on this queue at all). PF-R: every run counts
    /// the ticks that came late against the timer's interval (hitches) and
    /// the frame intervals no tick covered (missed).
    public func start(_ animations: [WindowAnimation], sink: MotionFrameSink) {
        let player = self.player ?? MotionPlayer(
            sink: sink, clock: context.playerClock, appName: context.playerAppName
        )
        self.player = player
        // A display-rate timer on the session queue: a tick only samples and
        // hands frames to per-app lanes (never an AX call here), so it costs
        // microseconds, and sampling by elapsed time keeps late ticks
        // honest. PA-03: paced to the display holding the moving windows
        // (60 Hz -> 16.7 ms, 120 Hz -> 8.3 ms), fixed for this motion.
        let interval = timerInterval ?? frameInterval(
            for: motionRefreshRate(animations: animations, displays: context.displayRefreshes())
        )
        player.start(animations, frameInterval: interval)
        lastAnimations = animations
        resizeProbes.probe(of: animations.filter { $0.sizeSchedule == .atStart }, frames: { $0.from })
        // Motion frames are unverified: the final pass must read these windows,
        // and the render check looks at them afterwards.
        for animation in animations {
            context.markUnverified(animation.id)
            animatingPids.insert(animation.id.pid)
        }
        guard timer == nil else {
            return
        }
        timerInterval = interval
        timer = scheduler.makeStrictTimer(start: 0, interval: interval) { [weak self] in
            self?.tick()
        }
    }

    public func stop() {
        animatingPids = []
        context.resetCoalescer()
        timer?.cancel()
        timer = nil
        timerInterval = nil
        player?.cancel()
    }

    /// One display frame (the timer's handler).
    func tick() {
        guard let player, player.isActive, !context.isShuttingDown() else {
            stop()
            return
        }
        if context.isMouseDown() {
            // Nothing moves under the cursor: abandon the flight, and let
            // the deferred reflow finish instantly after release.
            stop()
            context.armInstantPlacementForMouse()
            context.reflowAll()
            return
        }
        if context.takeCoalescedReflow() {
            // One merged retarget for every action since the last tick.
            context.performReflow()
            return
        }
        let tick = player.tick()
        // In place, only the windows written this tick; frame writes raise
        // moved events like any other write of ours.
        let now = context.now()
        for (id, frame) in tick.sampled {
            context.recordSampled(id, frame, now)
        }
        // The ring follows the focused window's sampled frame, and only
        // when that window moved this tick.
        if let focused = context.focusedWindow(), tick.sampled[focused] != nil {
            context.publishFocusRing()
        }
        if let summary = tick.summary {
            stop()
            context.log(.info, summary.logLine)
            context.learnResizeCapability(summary)
            // FI-03 grows land in the final pass: measure them for comparison.
            resizeProbes.probe(
                of: lastAnimations.filter { $0.sizeSchedule == .none },
                frames: { context.physicalFrame($0.id) ?? $0.from }
            )
            lastAnimations = []
            context.finalPass()
        }
    }
}
