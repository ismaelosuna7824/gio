import CoreGraphics
import Foundation

/// TG-01: one finger on a trackpad, as the adapter read it from a
/// MultitouchSupport contact frame. Position normalized to the trackpad
/// surface: x from 0 (left) to 1 (right), y from 0 (bottom) to 1 (top).
public struct TouchContact: Equatable, Sendable {
    public var id: Int32
    public var x: Double
    public var y: Double

    public init(id: Int32, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// TG-01: the fingers touching one trackpad at one instant (seconds, the
/// device's clock). Plain values: the adapter copies them off the callback
/// thread, nothing points into MultitouchSupport memory.
public struct TouchFrame: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var contacts: [TouchContact]

    public init(timestamp: TimeInterval, contacts: [TouchContact]) {
        self.timestamp = timestamp
        self.contacts = contacts
    }

    /// Mean position of the contacts (zero without any).
    public var centroid: CGPoint {
        guard !contacts.isEmpty else {
            return .zero
        }
        let count = Double(contacts.count)
        return CGPoint(
            x: contacts.reduce(0) { $0 + $1.x } / count,
            y: contacts.reduce(0) { $0 + $1.y } / count
        )
    }
}

/// TG-01: which frames cross from the touch callback thread to the session
/// queue. A resting finger produces frames at the trackpad's rate (pointer
/// movement, two-finger scrolling); only frames with enough fingers for a
/// gesture, plus the one frame that drops below that, are delivered.
/// `minimumFingers` 0 means no gesture is enabled: nothing crosses.
public struct TouchFrameGate: Sendable {
    public var minimumFingers: Int
    private var lastAdmitted = 0

    public init(minimumFingers: Int) {
        self.minimumFingers = minimumFingers
    }

    public mutating func admits(_ count: Int) -> Bool {
        guard minimumFingers > 0 else {
            lastAdmitted = 0
            return false
        }
        let admit = count >= minimumFingers || lastAdmitted >= minimumFingers
        if admit {
            lastAdmitted = count
        }
        return admit
    }
}

/// TG-01: velocity over the last `window` seconds of a swipe (position
/// units per second): the travel between the oldest and the newest sample
/// inside the window over the time between them. Fingers that rested
/// before lifting leave no movement inside the window: zero.
public struct SwipeVelocityTracker: Sendable {
    public static let window: TimeInterval = 0.08

    private var samples: [(time: TimeInterval, position: Double)] = []

    public init() {}

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    public mutating func push(position: Double, at time: TimeInterval) {
        if let last = samples.last, time < last.time {
            return
        }
        samples.append((time, position))
        let floor = time - Self.window
        if let keep = samples.firstIndex(where: { $0.time >= floor }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    public func velocity() -> Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else {
            return 0
        }
        return (last.position - first.position) / (last.time - first.time)
    }
}

public enum SwipeDirection: String, Equatable, Sendable {
    case up, down
}

/// TG-01: what the recognizer reports. Horizontal swipes are continuous
/// (began, changed by the centroid's x travel since the last event, ended
/// with the release velocity, or cancelled); vertical swipes are discrete,
/// one per touch-down, carrying the vertical travel (TG-08) when they fired.
public enum TrackpadGestureEvent: Equatable, Sendable {
    case scrollBegan(fingers: Int)
    case scrollChanged(dx: Double)
    case scrollEnded(velocity: Double)
    case scrollCancelled
    case verticalSwipe(fingers: Int, direction: SwipeDirection, distance: Double)
}

/// TG-01: which finger counts carry a gesture on each axis.
public struct GestureRecognizerSettings: Equatable, Sendable {
    /// Centroid travel (normalized trackpad units, about 3 mm on a laptop
    /// trackpad) before a gesture commits to an axis.
    public static let defaultCommitDistance = 0.03
    /// TG-08: vertical travel, as a fraction of the trackpad height, before
    /// a vertical swipe fires.
    public static let defaultSwipeDistance = 0.15
    /// TG-08: a vertical swipe stays at least this many times more vertical
    /// than horizontal (|dy| >= 2 |dx|); anything flatter is a diagonal.
    public static let verticalDominance = 2.0

    public var horizontalFingers: Int?
    public var verticalFingers: Set<Int>
    public var commitDistance: Double
    public var swipeDistance: Double

    public init(
        horizontalFingers: Int?, verticalFingers: Set<Int>,
        commitDistance: Double = defaultCommitDistance, swipeDistance: Double = defaultSwipeDistance
    ) {
        self.horizontalFingers = horizontalFingers
        self.verticalFingers = verticalFingers
        self.commitDistance = commitDistance
        self.swipeDistance = swipeDistance
    }

    /// The fewest fingers any gesture needs (0: none enabled).
    public var minimumFingers: Int {
        (verticalFingers.union(horizontalFingers.map { [$0] } ?? [])).min() ?? 0
    }

    func wants(_ count: Int) -> Bool {
        count == horizontalFingers || verticalFingers.contains(count)
    }
}

/// TG-01: pure swipe recognition from contact frames.
///
/// - A finger count with a gesture starts tracking at the frame it is
///   reached (the centroid jump of a landing finger is not movement).
/// - Before the commit distance, any count change restarts recognition.
/// - At the commit distance the axis locks (the larger component wins):
///   horizontal with the scroll count scrolls; an axis without a gesture
///   consumes the touch-down.
/// - TG-08: vertical with a vertical count must be clearly vertical
///   (|dy| >= `verticalDominance` |dx|), then waits: one swipe fires at the
///   frame the vertical travel from the touch-down reaches `swipeDistance`.
///   Turning diagonal or a finger count change while waiting consumes the
///   touch-down without an event; lifting short of the distance does nothing.
/// - While scrolling, an extra finger cancels (the gesture is abandoned) and
///   lifting a finger ends it with the release velocity.
/// - A consumed touch-down is released once fewer fingers than any gesture
///   needs remain.
public struct GestureRecognizer: Sendable {
    private enum Phase: Sendable {
        case idle
        case tracking(fingers: Int, origin: CGPoint, time: TimeInterval)
        case swiping(fingers: Int, origin: CGPoint)
        case scrolling(fingers: Int, lastX: Double, position: Double)
        case consumed
    }

    public var settings: GestureRecognizerSettings
    private var phase: Phase = .idle
    private var tracker = SwipeVelocityTracker()

    public init(settings: GestureRecognizerSettings) {
        self.settings = settings
    }

    public mutating func feed(_ frame: TouchFrame) -> [TrackpadGestureEvent] {
        let count = frame.contacts.count
        switch phase {
        case .idle:
            start(frame)
            return []
        case .tracking(let fingers, let origin, let time):
            guard count == fingers else {
                start(frame)
                return []
            }
            return commit(fingers: fingers, origin: origin, originTime: time, frame: frame)
        case .swiping(let fingers, let origin):
            guard count == fingers else {
                phase = .consumed
                release(count)
                return []
            }
            return swipe(fingers: fingers, origin: origin, frame: frame)
        case .scrolling(let fingers, let lastX, let position):
            if count == fingers {
                let x = Double(frame.centroid.x)
                let dx = x - lastX
                phase = .scrolling(fingers: fingers, lastX: x, position: position + dx)
                tracker.push(position: position + dx, at: frame.timestamp)
                return dx == 0 ? [] : [.scrollChanged(dx: dx)]
            }
            if count < fingers {
                tracker.push(position: position, at: frame.timestamp)
                let velocity = tracker.velocity()
                tracker.reset()
                phase = .consumed
                release(count)
                return [.scrollEnded(velocity: velocity)]
            }
            tracker.reset()
            phase = .consumed
            return [.scrollCancelled]
        case .consumed:
            release(count)
            return []
        }
    }

    private mutating func start(_ frame: TouchFrame) {
        let count = frame.contacts.count
        phase = settings.wants(count)
            ? .tracking(fingers: count, origin: frame.centroid, time: frame.timestamp)
            : .idle
    }

    private mutating func release(_ count: Int) {
        if count < max(settings.minimumFingers, 1) {
            phase = .idle
        }
    }

    private mutating func commit(
        fingers: Int, origin: CGPoint, originTime: TimeInterval, frame: TouchFrame
    ) -> [TrackpadGestureEvent] {
        let centroid = frame.centroid
        let dx = Double(centroid.x - origin.x)
        let dy = Double(centroid.y - origin.y)
        guard (dx * dx + dy * dy).squareRoot() >= settings.commitDistance else {
            return []
        }
        if abs(dx) >= abs(dy) {
            guard settings.horizontalFingers == fingers else {
                phase = .consumed
                return []
            }
            tracker.reset()
            tracker.push(position: 0, at: originTime)
            tracker.push(position: dx, at: frame.timestamp)
            phase = .scrolling(fingers: fingers, lastX: Double(centroid.x), position: dx)
            return [.scrollBegan(fingers: fingers), .scrollChanged(dx: dx)]
        }
        guard settings.verticalFingers.contains(fingers),
              abs(dy) >= GestureRecognizerSettings.verticalDominance * abs(dx)
        else {
            phase = .consumed
            return []
        }
        phase = .swiping(fingers: fingers, origin: origin)
        return swipe(fingers: fingers, origin: origin, frame: frame)
    }

    /// TG-08: waits for the vertical travel to reach the swipe distance.
    private mutating func swipe(fingers: Int, origin: CGPoint, frame: TouchFrame) -> [TrackpadGestureEvent] {
        let dx = Double(frame.centroid.x - origin.x)
        let dy = Double(frame.centroid.y - origin.y)
        if abs(dx) > abs(dy) / GestureRecognizerSettings.verticalDominance {
            phase = .consumed
            return []
        }
        guard abs(dy) >= settings.swipeDistance else {
            return []
        }
        phase = .consumed
        return [.verticalSwipe(fingers: fingers, direction: dy > 0 ? .up : .down, distance: abs(dy))]
    }
}
