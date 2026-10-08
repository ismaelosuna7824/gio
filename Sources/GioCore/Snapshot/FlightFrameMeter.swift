import Foundation

/// SM-12: what the display presented while one overlay flight was on screen.
/// `presented` counts display-synchronised callbacks on the overlay's screen
/// (a proxy for presented frames: the render server plays the tracks, the
/// callback shows whether that screen kept its cadence), `expected` is the
/// duration (from the first callback) times the screen's refresh rate, `hitches` counts
/// callback intervals over 1.5 refresh intervals.
public struct FlightFrameStats: Equatable, Sendable {
    public let presented: Int
    public let expected: Int
    public let hitches: Int
    public let duration: TimeInterval

    public init(presented: Int, expected: Int, hitches: Int, duration: TimeInterval) {
        self.presented = presented
        self.expected = expected
        self.hitches = hitches
        self.duration = duration
    }

    /// Frames the display should have shown and did not (never negative).
    public var dropped: Int {
        max(expected - presented, 0)
    }

    public var framesPerSecond: Double {
        duration > 0 ? Double(presented) / duration : 0
    }
}

/// SM-12: counts frames during a flight. Driven on main by the display link;
/// `frame(at:)` is an increment and one comparison, no allocation. At rest
/// (`isRunning == false`) every call is ignored. SM-13: the measurement
/// starts at the first callback (its timestamp is the origin; it is neither
/// counted nor a hitch), so the flight's setup and the wait for the first
/// vsync are not dropped frames.
public struct FlightFrameMeter: Sendable {
    /// An interval longer than this many refresh intervals is a hitch.
    public static let hitchFactor = 1.5

    public private(set) var isRunning = false
    private var refreshRate = 60.0
    private var hitchInterval = 1.5 / 60
    private var startedAt: TimeInterval = 0
    private var last: TimeInterval = 0
    private var hasOrigin = false
    private var presented = 0
    private var hitches = 0

    public init() {}

    /// The layers start flying at `now` (same clock as the frame timestamps).
    /// `now` is the origin only when no callback ever arrives.
    public mutating func start(at now: TimeInterval, refreshRate: Double) {
        let rate = max(refreshRate, 1)
        self.refreshRate = rate
        hitchInterval = Self.hitchFactor / rate
        startedAt = now
        last = now
        hasOrigin = false
        presented = 0
        hitches = 0
        isRunning = true
    }

    /// One display-synchronised callback with the frame's timestamp.
    public mutating func frame(at timestamp: TimeInterval) {
        guard isRunning else {
            return
        }
        guard hasOrigin else {
            hasOrigin = true
            startedAt = timestamp
            last = timestamp
            return
        }
        presented += 1
        if timestamp - last > hitchInterval {
            hitches += 1
        }
        last = timestamp
    }

    /// The flight landed: the stats, and the meter is at rest again.
    public mutating func finish(at now: TimeInterval) -> FlightFrameStats? {
        guard isRunning else {
            return nil
        }
        isRunning = false
        let duration = max(now - startedAt, 0)
        return FlightFrameStats(
            presented: presented, expected: Int((duration * refreshRate).rounded()), hitches: hitches,
            duration: duration
        )
    }

    /// The flight was cut short (abort, end, prime failure): nothing to report.
    public mutating func cancel() {
        isRunning = false
    }
}

/// Pure form over callback intervals after the first callback (the origin
/// at 0; `duration` is measured from it): the same arithmetic the meter
/// runs frame by frame.
public func flightFrameStats(intervals: [TimeInterval], refreshRate: Double, duration: TimeInterval) -> FlightFrameStats {
    var meter = FlightFrameMeter()
    meter.start(at: 0, refreshRate: refreshRate)
    meter.frame(at: 0)
    var now: TimeInterval = 0
    for interval in intervals {
        now += interval
        meter.frame(at: now)
    }
    return meter.finish(at: duration)!
}
