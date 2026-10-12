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
    /// PF-M: one tick's WindowServer frames, all in one transaction. Returns
    /// the windows moved; the player writes the others through Accessibility
    /// in the same tick. Never blocks.
    func submitWindowServerMotion(_ writes: [MotionWrite]) -> Set<WindowID>
    /// Per-app write stats accumulated since the last call (aggregated in
    /// place; no per-write entries).
    func takeMotionStats() -> [pid_t: MotionWriteStats]
}

public extension MotionFrameSink {
    func submitWindowServerMotion(_ writes: [MotionWrite]) -> Set<WindowID> { [] }
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
    /// Focused-grow: windows whose final size was written in the first frame.
    public let grewAtStart: Int
    /// Per-pid write stats of this run (feeds `ResizeCapability`); not part of equality.
    public let appStats: [pid_t: MotionWriteStats]
    /// SM-04: `ax` (frames written through Accessibility), `snapshot` (GPU
    /// overlay) or PF-O `live` (same-size windows through SkyLight per tick).
    public let renderer: String
    /// SM-12: snapshot flights, display-link intervals over 1.5 refresh
    /// intervals; PF-O: player runs, timer ticks over 1.5 frame intervals
    /// after the previous one (PF-R: AX runs too). Nil (and absent from the
    /// line) without a measurement.
    public let hitches: Int?
    /// PF-R: player runs, the frame intervals no tick covered (a tick 3.2
    /// intervals after the previous one missed 2), comparable with the
    /// snapshot line's expected-minus-presented `dropped`. Nil (and absent)
    /// for snapshot flights and without a timer interval.
    public let missed: Int?

    public init(
        windows: Int, frames: Int, dropped: Int, duration: TimeInterval,
        slowest: (app: String, milliseconds: Double)?, curve: String = "ease-out",
        sizeAnimated: Int = 0, appStats: [pid_t: MotionWriteStats] = [:], renderer: String = "ax",
        grewAtStart: Int = 0, hitches: Int? = nil, missed: Int? = nil
    ) {
        self.hitches = hitches
        self.missed = missed
        self.grewAtStart = grewAtStart
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
            && lhs.slowest?.milliseconds == rhs.slowest?.milliseconds && lhs.hitches == rhs.hitches
            && lhs.missed == rhs.missed
    }

    /// SM-12: a finished overlay flight. `frames` are the frames the display
    /// presented during it, `dropped` the expected ones it did not; without
    /// a measurement (no display link) both are 0 and `hitches` is absent.
    public static func snapshotFlight(windows: Int, duration: TimeInterval, frames: FlightFrameStats?) -> MotionSummary {
        MotionSummary(
            windows: windows, frames: frames?.presented ?? 0, dropped: frames?.dropped ?? 0, duration: duration,
            slowest: nil, curve: "spring", renderer: "snapshot", hitches: frames?.hitches
        )
    }

    /// `anim done windows=N frames=F dropped=D [missed=M] [hitches=H] duration=Xms slowest=<app> Yms curve=<curve> sizeAnimated=S renderer=ax|live|snapshot grewAtStart=G`
    /// AX and live: `frames` counts sampled display ticks, `dropped` counts
    /// per-app frames skipped because that app was still writing (live: only
    /// the resizing windows have app lanes), `missed` the frame intervals no
    /// tick covered and `hitches` the late ticks (PF-R: both renderers).
    /// Snapshot (SM-12): presented frames, expected minus presented, and
    /// hitches. IDs and app names only.
    public var logLine: String {
        let slowestText = slowest.map { "\($0.app) \(Int($0.milliseconds.rounded()))ms" } ?? "none"
        let missedText = missed.map { "missed=\($0) " } ?? ""
        let hitchText = hitches.map { "hitches=\($0) " } ?? ""
        return "anim done windows=\(windows) frames=\(frames) dropped=\(dropped) \(missedText)\(hitchText)"
            + "duration=\(Int((duration * 1000).rounded()))ms slowest=\(slowestText) curve=\(curve) sizeAnimated=\(sizeAnimated) renderer=\(renderer) grewAtStart=\(grewAtStart)"
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
    private var runGrewAtStart: Set<WindowID> = []
    /// PF-O: the renderer named in the run's summary and the timer interval
    /// its late ticks are measured against (nil: no hitch count, AX runs).
    private var renderer: RendererKind = .ax
    private var frameInterval: TimeInterval?
    private var hitches = 0
    /// PF-R: frame intervals no tick covered this run.
    private var missed = 0
    private var lastTickAt: TimeInterval?

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
    /// PF-O: `renderer` names the run in its summary and, with
    /// `frameInterval` (the timer's), ticks later than 1.5 intervals after
    /// the previous one count as hitches; the latest start sets both.
    public func start(_ next: [WindowAnimation], renderer: RendererKind = .ax, frameInterval: TimeInterval? = nil) {
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
            runGrewAtStart = []
            hitches = 0
            missed = 0
            lastTickAt = nil
        }
        self.renderer = renderer
        self.frameInterval = frameInterval
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
            if animation.sizeSchedule.interpolates {
                runSizeAnimated.insert(animation.id)
            } else if animation.sizeSchedule == .atStart, growsAtAll(animation) {
                runGrewAtStart.insert(animation.id)
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
        let now = clock()
        let elapsed = now - segmentStart
        lastElapsed = elapsed
        if let frameInterval, let lastTickAt {
            let gap = now - lastTickAt
            if gap > frameInterval * 1.5 {
                hitches += 1
            }
            missed += max(0, Int((gap / frameInterval).rounded()) - 1)
        }
        lastTickAt = now
        frames += 1
        var sampled: [WindowID: CGRect] = [:]
        var perPid: [pid_t: [MotionWrite]] = [:]
        var serverWrites: [MotionWrite] = []
        for animation in animations {
            let frame = wholePoints(
                animation.motionFrame(at: elapsed), size: animation.sizeSchedule.interpolates
            )
            sampled[animation.id] = frame
            let last = submitted[animation.id] ?? animation.from
            if differs(frame, last) {
                let write = MotionWrite(id: animation.id, from: last, to: frame)
                if animation.transport == .windowServer {
                    serverWrites.append(write)
                } else {
                    perPid[animation.id.pid, default: []].append(write)
                }
            }
        }
        // PF-M/PF-O: WindowServer flights first (hide and reveal; with the
        // live renderer every same-size one), in one transaction; what the
        // WindowServer did not take goes through Accessibility this tick.
        if !serverWrites.isEmpty {
            let moved = sink.submitWindowServerMotion(serverWrites)
            for write in serverWrites {
                if moved.contains(write.id) {
                    submitted[write.id] = write.to
                } else {
                    perPid[write.id.pid, default: []].append(write)
                }
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
        // PF-A: no wait on the lanes here. A slow app's in-flight write used
        // to hold the session queue (and stretch `duration`) for up to 0.3 s;
        // the final pass waits briefly for the apps it writes and defers the
        // rest. A write still running lands in the next run's stats.
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
            sizeAnimated: runSizeAnimated.count, appStats: stats, renderer: renderer.rawValue,
            grewAtStart: runGrewAtStart.count, hitches: frameInterval == nil ? nil : hitches,
            missed: frameInterval == nil ? nil : missed
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
