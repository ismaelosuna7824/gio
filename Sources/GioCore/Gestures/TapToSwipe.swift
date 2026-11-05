import CoreGraphics
import Foundation

/// TG-10: why tap-to-swipe turned off.
public enum TapToSwipeDisarm: String, Equatable, Sendable {
    /// `armedWindow` passed without fingers on the trackpad.
    case expired
    /// Another three-finger tap.
    case tap
    /// A mouse button went down.
    case mouse
    /// `[gestures] tap-to-swipe` was turned off.
    case disabled
}

/// TG-10/TG-12: what `TapToSwipe` reports. The scroll events mean what the
/// recognizer's do (TG-03): the strip follows `dx`, the release hands over
/// the velocity (trackpad widths per second), a cancel abandons.
public enum TapToSwipeEvent: Equatable, Sendable {
    case armed
    case scrollBegan
    case scrollChanged(dx: Double)
    case scrollEnded(velocity: Double)
    case scrollCancelled
    case step(SwipeDirection)
    case disarmed(TapToSwipeDisarm)
}

/// TG-10 "tap to swipe": a quick three-finger tap arms a mode in which
/// two-finger strokes move windows and workspaces, so neither macOS's
/// three-finger swipes nor two-finger scrolling outside the mode are lost.
/// Pure: contact frames in, events out, time from the frames' own clock.
///
/// - Tap: a touch with exactly `tapFingers` contacts at its peak, lifted
///   (fewer than three contacts) within `maxTapDuration` of the first
///   three-finger frame, its centroid never more than `maxTapTravel` from
///   where it started. Arms when off, disarms when on. While armed a tap can
///   only start between strokes (a third finger on a moving stroke is no tap).
/// - Armed: `armedUntil` is `armedWindow` after the last frame seen while
///   armed, so fingers on the trackpad keep it on and every lift renews it;
///   a frame past it disarms (`expired`) before it counts, and `expire()` is
///   the session's timer for when no frame comes.
/// - Stroke: `strokeFingers` landing from a lift start it. At the
///   recognizer's commit distance the larger axis wins. TG-12: horizontal
///   scrolls the strip with the fingers (began, changed per frame, ended
///   with the 80 ms release velocity at the lift, cancelled by an extra
///   finger or a disarm); vertical must be `verticalDominance` times more
///   vertical and fires one step at `stepDistance`, consumed if it turns
///   diagonal. Any other finger count is ignored; the fingers lift (fewer
///   than two) before the next stroke.
public struct TapToSwipe: Sendable {
    public static let tapFingers = 3
    public static let strokeFingers = 2
    /// Longest touch that is still a tap (first three-finger frame to lift).
    public static let maxTapDuration: TimeInterval = 0.3
    /// Farthest the tap's centroid may wander (normalized trackpad units,
    /// about 2 mm on a laptop trackpad): a three-finger drag is no tap.
    public static let maxTapTravel = 0.02
    /// How long the mode stays on after the fingers last touched.
    public static let armedWindow: TimeInterval = 2.5
    /// TG-12: default travel (fraction of the trackpad height) before an
    /// up/down stroke steps. Horizontal strokes follow the fingers instead.
    public static let defaultStepDistance = 0.1

    /// Up/down travel before a stroke steps (`[gestures]
    /// tap-to-swipe-distance`); a change applies from the next frame.
    public var stepDistance: Double

    private enum Tap: Sendable {
        case none
        case candidate(start: TimeInterval, origin: CGPoint)
        case spoiled
    }

    private enum Stroke: Sendable {
        /// Fingers lifted: the next two-finger frame starts a stroke.
        case ready
        /// Waiting for fewer than two fingers (a step fired, a diagonal,
        /// a cancelled scroll, another count).
        case lifting
        /// Landed, short of the commit distance.
        case tracking(origin: CGPoint, time: TimeInterval)
        /// Vertical, waiting for `stepDistance`.
        case swiping(origin: CGPoint)
        /// Horizontal: the strip follows `position` (travel since landing).
        case scrolling(lastX: Double, position: Double)
    }

    public private(set) var armedUntil: TimeInterval?
    private var tap = Tap.none
    private var stroke = Stroke.lifting
    private var velocity = SwipeVelocityTracker()

    public init(stepDistance: Double = defaultStepDistance) {
        self.stepDistance = stepDistance
    }

    public var isArmed: Bool {
        armedUntil != nil
    }

    public mutating func feed(_ frame: TouchFrame) -> [TapToSwipeEvent] {
        var events: [TapToSwipeEvent] = []
        if let until = armedUntil, frame.timestamp > until {
            events += disarm(.expired)
        }
        let count = frame.contacts.count
        if trackTap(frame) {
            if isArmed {
                events += disarm(.tap)
                return events
            }
            events.append(.armed)
            stroke = count < Self.strokeFingers ? .ready : .lifting
            armedUntil = frame.timestamp + Self.armedWindow
            return events
        }
        if isArmed {
            events += trackStroke(frame)
            armedUntil = frame.timestamp + Self.armedWindow
        }
        return events
    }

    /// The session's timer: the window passed with no frame.
    public mutating func expire() -> [TapToSwipeEvent] {
        disarm(.expired)
    }

    /// A scroll in progress is cancelled first.
    public mutating func disarm(_ reason: TapToSwipeDisarm) -> [TapToSwipeEvent] {
        guard isArmed else {
            return []
        }
        armedUntil = nil
        var events: [TapToSwipeEvent] = []
        if case .scrolling = stroke {
            velocity.reset()
            events.append(.scrollCancelled)
        }
        stroke = .lifting
        events.append(.disarmed(reason))
        return events
    }

    /// Between strokes (or while off) three fingers may start a tap.
    private var tapMayStart: Bool {
        guard isArmed else {
            return true
        }
        switch stroke {
        case .ready, .tracking: return true
        case .lifting, .swiping, .scrolling: return false
        }
    }

    /// True at the lift of a tap.
    private mutating func trackTap(_ frame: TouchFrame) -> Bool {
        let count = frame.contacts.count
        if count < Self.tapFingers {
            defer { tap = .none }
            guard case .candidate(let start, _) = tap else {
                return false
            }
            return frame.timestamp - start <= Self.maxTapDuration
        }
        guard count == Self.tapFingers else {
            tap = .spoiled
            return false
        }
        switch tap {
        case .none:
            tap = tapMayStart ? .candidate(start: frame.timestamp, origin: frame.centroid) : .spoiled
        case .candidate(let start, let origin):
            if frame.timestamp - start > Self.maxTapDuration || distance(frame.centroid, origin) > Self.maxTapTravel {
                tap = .spoiled
            }
        case .spoiled:
            break
        }
        return false
    }

    private mutating func trackStroke(_ frame: TouchFrame) -> [TapToSwipeEvent] {
        let count = frame.contacts.count
        if count != Self.strokeFingers {
            var events: [TapToSwipeEvent] = []
            if case .scrolling(_, let position) = stroke {
                if count < Self.strokeFingers {
                    velocity.push(position: position, at: frame.timestamp)
                    events.append(.scrollEnded(velocity: velocity.velocity()))
                } else {
                    events.append(.scrollCancelled)
                }
                velocity.reset()
            }
            stroke = count < Self.strokeFingers ? .ready : .lifting
            return events
        }
        switch stroke {
        case .ready:
            stroke = .tracking(origin: frame.centroid, time: frame.timestamp)
            return []
        case .lifting:
            return []
        case .tracking(let origin, let time):
            return commit(origin: origin, originTime: time, frame: frame)
        case .swiping(let origin):
            return swipe(origin: origin, frame: frame)
        case .scrolling(let lastX, let position):
            let x = Double(frame.centroid.x)
            let dx = x - lastX
            stroke = .scrolling(lastX: x, position: position + dx)
            velocity.push(position: position + dx, at: frame.timestamp)
            return dx == 0 ? [] : [.scrollChanged(dx: dx)]
        }
    }

    /// At the commit distance the larger axis wins (like the recognizer).
    private mutating func commit(origin: CGPoint, originTime: TimeInterval, frame: TouchFrame) -> [TapToSwipeEvent] {
        let dx = Double(frame.centroid.x - origin.x)
        let dy = Double(frame.centroid.y - origin.y)
        guard (dx * dx + dy * dy).squareRoot() >= GestureRecognizerSettings.defaultCommitDistance else {
            return []
        }
        if abs(dx) >= abs(dy) {
            velocity.reset()
            velocity.push(position: 0, at: originTime)
            velocity.push(position: dx, at: frame.timestamp)
            stroke = .scrolling(lastX: Double(frame.centroid.x), position: dx)
            return [.scrollBegan, .scrollChanged(dx: dx)]
        }
        guard abs(dy) >= GestureRecognizerSettings.verticalDominance * abs(dx) else {
            stroke = .lifting
            return []
        }
        stroke = .swiping(origin: origin)
        return swipe(origin: origin, frame: frame)
    }

    /// One step once the vertical travel reaches `stepDistance`.
    private mutating func swipe(origin: CGPoint, frame: TouchFrame) -> [TapToSwipeEvent] {
        let dx = Double(frame.centroid.x - origin.x)
        let dy = Double(frame.centroid.y - origin.y)
        if abs(dx) > abs(dy) / GestureRecognizerSettings.verticalDominance {
            stroke = .lifting
            return []
        }
        guard abs(dy) >= stepDistance else {
            return []
        }
        stroke = .lifting
        return [.step(dy > 0 ? .up : .down)]
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
