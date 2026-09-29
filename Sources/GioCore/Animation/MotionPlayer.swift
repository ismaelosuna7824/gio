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

/// Where the player's frames go. `submitMotion` never blocks and never
/// queues: it returns false when the app's previous frame is still being
/// written, and the player drops that frame for that app.
public protocol MotionFrameSink: AnyObject {
    func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool
    /// Blocks (bounded) until every accepted frame has been written.
    func waitForMotionIdle(timeout: TimeInterval)
    /// Write timings accumulated since the last call.
    func takeMotionTimings() -> [WindowWriteTiming]
}

/// What one finished animation cost, for the live fps judgement.
public struct MotionSummary: Equatable, Sendable {
    public let windows: Int
    public let frames: Int
    public let dropped: Int
    public let duration: TimeInterval
    /// The app with the single slowest frame write.
    public let slowest: (app: String, milliseconds: Double)?

    public init(
        windows: Int, frames: Int, dropped: Int, duration: TimeInterval,
        slowest: (app: String, milliseconds: Double)?
    ) {
        self.windows = windows
        self.frames = frames
        self.dropped = dropped
        self.duration = duration
        self.slowest = slowest
    }

    public static func == (lhs: MotionSummary, rhs: MotionSummary) -> Bool {
        lhs.windows == rhs.windows && lhs.frames == rhs.frames && lhs.dropped == rhs.dropped
            && lhs.duration == rhs.duration && lhs.slowest?.app == rhs.slowest?.app
            && lhs.slowest?.milliseconds == rhs.slowest?.milliseconds
    }

    /// `anim done windows=N frames=F dropped=D duration=Xms slowest=<app> Yms`
    /// `frames` counts sampled display ticks, `dropped` counts per-app frames
    /// skipped because that app was still writing. IDs and app names only.
    public var logLine: String {
        let slowestText = slowest.map { "\($0.app) \(Int($0.milliseconds.rounded()))ms" } ?? "none"
        return "anim done windows=\(windows) frames=\(frames) dropped=\(dropped) "
            + "duration=\(Int((duration * 1000).rounded()))ms slowest=\(slowestText)"
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
    private let appName: @Sendable (pid_t) -> String?
    private let tolerance: CGFloat = 0.5

    private var animations: [WindowAnimation] = []
    private var segmentStart: TimeInterval = 0
    private var runStart: TimeInterval = 0
    private var submitted: [WindowID: CGRect] = [:]
    private var runWindows: Set<WindowID> = []
    private var frames = 0
    private var dropped = 0

    public private(set) var sampledFrames: [WindowID: CGRect] = [:]

    public init(
        sink: MotionFrameSink, clock: @escaping ReflowClock = systemReflowClock,
        appName: @escaping @Sendable (pid_t) -> String? = { _ in nil }
    ) {
        self.sink = sink
        self.clock = clock
        self.appName = appName
    }

    public var isActive: Bool { !animations.isEmpty }

    /// Begin, or retarget a run in flight: the new animations replace the
    /// old ones and time restarts, while the run's counters continue.
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
        }
        segmentStart = now
        animations = next
        for animation in next {
            runWindows.insert(animation.id)
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
        frames += 1
        var sampled: [WindowID: CGRect] = [:]
        var perPid: [pid_t: [MotionWrite]] = [:]
        for animation in animations {
            let frame = animation.motionFrame(at: elapsed)
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
        var worst: [pid_t: WindowWriteTiming] = [:]
        for timing in sink.takeMotionTimings() where timing.milliseconds > (worst[timing.id.pid]?.milliseconds ?? -1) {
            worst[timing.id.pid] = timing
        }
        let slowest = worst.keys.sorted().compactMap { worst[$0] }
            .reduce(nil as WindowWriteTiming?) { best, next in
                guard let best else { return next }
                return next.milliseconds > best.milliseconds ? next : best
            }
            .map { (app: $0.app.isEmpty ? (appName($0.id.pid) ?? "pid\($0.id.pid)") : $0.app, milliseconds: $0.milliseconds) }
        let summary = MotionSummary(
            windows: runWindows.count, frames: frames, dropped: dropped,
            duration: clock() - runStart, slowest: slowest
        )
        animations = []
        submitted = [:]
        return summary
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > tolerance || abs(a.origin.y - b.origin.y) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }
}
