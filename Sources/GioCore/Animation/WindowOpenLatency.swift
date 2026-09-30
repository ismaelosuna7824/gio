import CoreGraphics
import Foundation

/// PF-02: what a live arrival asks of the next pass.
public enum WindowOpenArrival: String, Equatable, Sendable {
    /// Lands on a shown workspace: enters from just below its tile (NA-02).
    case enter
    /// Lands on a hidden workspace (or minimized): the pass only places or
    /// parks it; nothing is animated in.
    case place
    /// Took the user to its workspace: the switch, started by the pass that
    /// the registration runs, brings it in. No separate entry motion.
    case followSwitch
}

/// PF-02: an entry is only worth its pre-position write and spring when the
/// window lands where the user looks and the user stays there.
public func planWindowOpenArrival(destinationShown: Bool, followed: Bool, minimized: Bool) -> WindowOpenArrival {
    if minimized {
        return .place
    }
    if followed {
        return .followSwitch
    }
    return destinationShown ? .enter : .place
}

/// PF-02: which pre-position writes may go out now and which wait for the
/// in-flight motion's queued lane writes to drain.
public struct PrepositionWritePlan: Equatable, Sendable {
    public var immediate: [WindowID: CGRect]
    public var afterMotionIdle: [WindowID: CGRect]

    /// True only when something must wait for a motion in flight.
    public var waitsForMotion: Bool { !afterMotionIdle.isEmpty }
}

/// PF-02: a newly opened window has no queued motion frame that could land
/// after its pre-position, so its entry write never waits: it merges into
/// the running motion (which retargets). Switch pre-positions of windows the
/// motion may still be writing keep waiting, as before.
public func planPrepositionWrites(
    _ frames: [WindowID: CGRect], entries: Set<WindowID>, motionInFlight: Bool
) -> PrepositionWritePlan {
    guard motionInFlight else {
        return PrepositionWritePlan(immediate: frames, afterMotionIdle: [:])
    }
    var plan = PrepositionWritePlan(immediate: [:], afterMotionIdle: [:])
    for (id, frame) in frames {
        if entries.contains(id) {
            plan.immediate[id] = frame
        } else {
            plan.afterMotionIdle[id] = frame
        }
    }
    return plan
}

/// PF-02: one opened window's timings (session uptime seconds). Carries ids
/// and the app name only, never a title.
public struct WindowOpenTiming: Equatable, Sendable {
    public var id: WindowID
    public var app: String
    /// The first created event (the first registration attempt).
    public var createdAt: TimeInterval
    public var registeredAt: TimeInterval
    public var retries: Int
    /// From the created event's delivery (main thread) until the session
    /// queue started the first registration attempt: time spent behind
    /// whatever the queue was running (a settle pass, a motion wait). Zero
    /// when the delivery time is unknown (focus-adoption registration).
    public var queueWait: TimeInterval = 0
    /// AX reads and admission classification, summed over every attempt.
    public var classify: TimeInterval = 0
    /// The destination workspace's name, else its 1-based index.
    public var workspace: String
    public var follow: Bool
    public var firstWriteAt: TimeInterval?
    public var waitedForMotion: TimeInterval = 0

    public init(
        id: WindowID, app: String, createdAt: TimeInterval, registeredAt: TimeInterval,
        retries: Int, workspace: String, follow: Bool
    ) {
        self.id = id
        self.app = app
        self.createdAt = createdAt
        self.registeredAt = registeredAt
        self.retries = retries
        self.workspace = workspace
        self.follow = follow
    }
}

/// PF-02: the per-window open timeline. Registration opens a record, the
/// first pass that writes anything stamps the first write (and any wait for
/// motion it did), and the next settle (the instant pass that puts windows
/// on their final frames) closes it into one log line.
public struct WindowOpenTimeline: Sendable {
    /// Records kept at most; the oldest is dropped (a window never written).
    public static let capacity = 32

    private var records: [WindowID: WindowOpenTiming] = [:]

    public init() {}

    public var count: Int { records.count }

    public mutating func registered(_ timing: WindowOpenTiming) {
        records[timing.id] = timing
        while records.count > Self.capacity,
              let oldest = records.values.min(by: { $0.registeredAt < $1.registeredAt })
        {
            records.removeValue(forKey: oldest.id)
        }
    }

    public mutating func forget(_ id: WindowID) {
        records.removeValue(forKey: id)
    }

    /// A pass started writing: the first write of every record without one.
    public mutating func wrote(at now: TimeInterval, waitedForMotion: TimeInterval) {
        for id in records.keys where records[id]?.firstWriteAt == nil {
            records[id]?.firstWriteAt = now
            records[id]?.waitedForMotion = waitedForMotion
        }
    }

    /// Windows are on their final frames: one line per written record.
    public mutating func settled(at now: TimeInterval) -> [String] {
        let done = records.values.filter { $0.firstWriteAt != nil }.sorted { $0.id < $1.id }
        for timing in done {
            records.removeValue(forKey: timing.id)
        }
        return done.map { windowOpenTimelineLine($0, settledAt: now) }
    }
}

/// PF-02: `window open id= app= createdEvent→registered ms= queueWait ms= classify ms=
/// registered→firstWrite ms= →settled ms= total ms= workspace= follow= retries= waitedForMotion ms=`.
/// `createdEvent→registered` = `queueWait` + `classify` + retry delays + registration bookkeeping.
public func windowOpenTimelineLine(_ timing: WindowOpenTiming, settledAt: TimeInterval) -> String {
    func ms(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1000).rounded())
    }
    let firstWrite = timing.firstWriteAt ?? settledAt
    return "window open id=\(timing.id.pid):\(timing.id.elementID) app=\(timing.app)"
        + " createdEvent→registered ms=\(ms(timing.registeredAt - timing.createdAt))"
        + " queueWait ms=\(ms(timing.queueWait)) classify ms=\(ms(timing.classify))"
        + " registered→firstWrite ms=\(ms(firstWrite - timing.registeredAt))"
        + " →settled ms=\(ms(settledAt - firstWrite))"
        + " total ms=\(ms(settledAt - timing.createdAt))"
        + " workspace=\(timing.workspace) follow=\(timing.follow) retries=\(timing.retries)"
        + " waitedForMotion ms=\(ms(timing.waitedForMotion))"
}
