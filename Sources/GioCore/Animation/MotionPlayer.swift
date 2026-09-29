import CoreGraphics
import Foundation

/// One in-flight frame for one window: `from` is the last frame the app was
/// actually given, so the writer knows which attributes changed.
public struct MotionWrite: Equatable, Sendable {
    public let id: WindowID
    public let from: CGRect
    public let to: CGRect

    public init(id: WindowID, from: CGRect, to: CGRect) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// Where the player's frames go. `submitMotion` never blocks: it returns
/// false when the app cannot take a frame at all (the player then counts a
/// drop and resumes from the last frame the app really received). A sink may
/// keep only the latest pending frame per app and report the overwritten ones
/// as `MotionWriteStats.drops`.
public protocol MotionFrameSink: AnyObject {
    func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool
    /// Blocks (bounded) until every accepted frame has been written.
    func waitForMotionIdle(timeout: TimeInterval)
    /// Per-app write stats accumulated since the last call (aggregated in
    /// place; no per-write entries).
    func takeMotionStats() -> [pid_t: MotionWriteStats]
}

/// What one finished animation cost, for the live fps judgement.
public struct MotionSummary: Equatable, Sendable {
    public let windows: Int
    public let frames: Int
    public let dropped: Int
    public let duration: TimeInterval
    /// The app with the single slowest frame write.
    public let slowest: (app: String, milliseconds: Double)?
    /// NF-04: `spring` or `ease-out`.
    public let curve: String
    /// PA-06: windows whose size followed the flight instead of the final pass.
    public let sizeAnimated: Int
    /// Per-pid write stats of this run (feeds `ResizeCapability`); not part of equality.
    public let appStats: [pid_t: MotionWriteStats]
    /// SM-04: `ax` (frames written through Accessibility) or `snapshot` (GPU overlay).
    public let renderer: String

    public init(
        windows: Int, frames: Int, dropped: Int, duration: TimeInterval,
        slowest: (app: String, milliseconds: Double)?, curve: String = "ease-out",
        sizeAnimated: Int = 0, appStats: [pid_t: MotionWriteStats] = [:], renderer: String = "ax"
    ) {
        self.renderer = renderer
        self.curve = curve
        self.sizeAnimated = sizeAnimated
        self.appStats = appStats
        self.windows = windows
        self.frames = frames
        self.dropped = dropped
        self.duration = duration
        self.slowest = slowest
    }

    public static func == (lhs: MotionSummary, rhs: MotionSummary) -> Bool {
        lhs.windows == rhs.windows && lhs.curve == rhs.curve && lhs.frames == rhs.frames && lhs.dropped == rhs.dropped
            && lhs.duration == rhs.duration && lhs.slowest?.app == rhs.slowest?.app
            && lhs.slowest?.milliseconds == rhs.slowest?.milliseconds
    }

    /// `anim done windows=N frames=F dropped=D duration=Xms slowest=<app> Yms curve=<curve> sizeAnimated=S renderer=ax|snapshot`
    /// `frames` counts sampled display ticks, `dropped` counts per-app frames
    /// skipped because that app was still writing. IDs and app names only.
    public var logLine: String {
        let slowestText = slowest.map { "\($0.app) \(Int($0.milliseconds.rounded()))ms" } ?? "none"
        return "anim done windows=\(windows) frames=\(frames) dropped=\(dropped) "
            + "duration=\(Int((duration * 1000).rounded()))ms slowest=\(slowestText) curve=\(curve) sizeAnimated=\(sizeAnimated) renderer=\(renderer)"
    }
}

public struct MotionTick {
    /// Frames sampled this tick (what the windows are being moved to).
    public let sampled: [WindowID: CGRect]
    /// Non-nil exactly when this tick completed the animation.
    public let summary: MotionSummary?
}

/// MO-04 frame player. Deterministic given its clock: the host calls `tick`
/// on a display-rate timer; each tick samples every `WindowAnimation` at the
/// elapsed time and hands the changed frames to the sink, one submission per
/// app. Not thread-safe: drive it from one queue. It never touches logical
/// state — retargeting is just `start` with animations planned from
/// `sampledFrames`, so nothing snaps back.
public final class MotionPlayer {
    private let sink: MotionFrameSink
    private let clock: ReflowClock
    private let names: AppNameCache
    private let tolerance = frameWriteTolerance

    private var animations: [WindowAnimation] = []
    private var segmentStart: TimeInterval = 0
    private var runStart: TimeInterval = 0
    private var submitted: [WindowID: CGRect] = [:]
    private var runWindows: Set<WindowID> = []
    private var frames = 0
    private var dropped = 0
    /// Elapsed time (in the current segment) of the last sampled tick: the
    /// instant the windows' last written positions belong to.
    private var lastElapsed: TimeInterval = 0
    private var runUsedSpring = false
    private var runSizeAnimated: Set<WindowID> = []

    public private(set) var sampledFrames: [WindowID: CGRect] = [:]

    public init(
        sink: MotionFrameSink, clock: @escaping ReflowClock = systemReflowClock,
        appName: @escaping @Sendable (pid_t) -> String? = { _ in nil }
    ) {
        self.sink = sink
        self.clock = clock
        self.names = AppNameCache(resolve: appName)
    }

    public var isActive: Bool { !animations.isEmpty }

    /// The flights in progress (tests inspect retarget velocities).
    var currentAnimations: [WindowAnimation] { animations }

    /// Begin, or retarget a run in flight: the new animations replace the
    /// old ones and time restarts, while the run's counters continue. A spring
    /// flight inherits the velocity its predecessor had at the last sampled
    /// instant (NF-04), so rapid retargets flow instead of restarting from rest.
    public func start(_ next: [WindowAnimation]) {
        guard !next.isEmpty else {
            return
        }
        let now = clock()
        if !isActive {
            runStart = now
            frames = 0
            dropped = 0
            runWindows = []
            submitted = [:]
            sampledFrames = [:]
            runUsedSpring = false
            runSizeAnimated = []
        }
        var previous: [WindowID: WindowAnimation] = [:]
        for animation in animations {
            previous[animation.id] = animation
        }
        let sampledAt = lastElapsed
        segmentStart = now
        lastElapsed = 0
        animations = next.map { animation in
            guard let spring = animation.spring, let old = previous[animation.id], old.spring != nil else {
                return animation
            }
            return animation.springing(spring, velocity: old.velocity(at: sampledAt))
        }
        runUsedSpring = runUsedSpring || animations.contains { $0.spring != nil }
        for animation in next {
            runWindows.insert(animation.id)
            if animation.sizeSchedule != .none {
                runSizeAnimated.insert(animation.id)
            }
            if submitted[animation.id] == nil {
                submitted[animation.id] = animation.from
            }
        }
    }

    public func cancel() {
        animations = []
        sampledFrames = [:]
        submitted = [:]
    }

    public func tick() -> MotionTick {
        guard isActive else {
            return MotionTick(sampled: [:], summary: nil)
        }
        let elapsed = clock() - segmentStart
        lastElapsed = elapsed
        frames += 1
        var sampled: [WindowID: CGRect] = [:]
        var perPid: [pid_t: [MotionWrite]] = [:]
        for animation in animations {
            let frame = wholePoints(
                animation.motionFrame(at: elapsed), size: animation.sizeSchedule != .none
            )
            sampled[animation.id] = frame
            let last = submitted[animation.id] ?? animation.from
            if differs(frame, last) {
                perPid[animation.id.pid, default: []].append(
                    MotionWrite(id: animation.id, from: last, to: frame)
                )
            }
        }
        for pid in perPid.keys.sorted() {
            let writes = perPid[pid]!
            if sink.submitMotion(pid: pid, writes: writes) {
                for write in writes {
                    submitted[write.id] = write.to
                }
            } else {
                dropped += 1
            }
        }
        sampledFrames.merge(sampled) { _, new in new }
        guard animations.allSatisfy({ $0.isComplete(at: elapsed) }) else {
            return MotionTick(sampled: sampled, summary: nil)
        }
        return MotionTick(sampled: sampled, summary: finish())
    }

    private func finish() -> MotionSummary {
        sink.waitForMotionIdle(timeout: 0.3)
        // The app name is resolved once, here, for the single slowest pid.
        let stats = sink.takeMotionStats()
        var slowestPid: pid_t?
        for pid in stats.keys.sorted() {
            if slowestPid == nil || stats[pid]!.maxMilliseconds > stats[slowestPid!]!.maxMilliseconds {
                slowestPid = pid
            }
        }
        let slowest = slowestPid.map { (app: names.display($0), milliseconds: stats[$0]!.maxMilliseconds) }
        let summary = MotionSummary(
            windows: runWindows.count, frames: frames,
            // Rejected submissions plus frames the lanes overwrote before writing them.
            dropped: dropped + stats.values.reduce(0) { $0 + $1.drops },
            duration: clock() - runStart, slowest: slowest,
            curve: runUsedSpring ? "spring" : "ease-out",
            sizeAnimated: runSizeAnimated.count, appStats: stats
        )
        animations = []
        submitted = [:]
        return summary
    }

    /// Origins are written on whole points: sub-point steps are invisible and
    /// the writer ignores them anyway. Sizes stay exact (FI-03) unless the
    /// window's size follows the flight (PA-06), where they round too.
    private func wholePoints(_ frame: CGRect, size interpolated: Bool) -> CGRect {
        let size = interpolated
            ? CGSize(width: frame.size.width.rounded(), height: frame.size.height.rounded())
            : frame.size
        return CGRect(origin: CGPoint(x: frame.origin.x.rounded(), y: frame.origin.y.rounded()), size: size)
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > tolerance || abs(a.origin.y - b.origin.y) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }
}
