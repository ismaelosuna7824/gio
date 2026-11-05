import CoreGraphics
import Foundation

/// TG-10: which way a tap-to-swipe stroke went (the fingers' direction,
/// trackpad y up).
public enum TapSwipeDirection: String, Equatable, Sendable {
    case left, right, up, down
}

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

/// TG-10: what `TapToSwipe` reports.
public enum TapToSwipeEvent: Equatable, Sendable {
    case armed
    case step(TapSwipeDirection)
    case disarmed(TapToSwipeDisarm)
}

/// TG-10 "tap to swipe": a quick three-finger tap arms a mode in which each
/// two-finger stroke is one step (a window left or right, a workspace up or
/// down), so changing windows needs neither macOS's three-finger swipes nor
/// giving up two-finger scrolling outside the mode. Pure: contact frames in,
/// events out, time from the frames' own clock.
///
/// - Tap: a touch with exactly `tapFingers` contacts at its peak, lifted
///   (fewer than three contacts) within `maxTapDuration` of the first
///   three-finger frame, its centroid never more than `maxTapTravel` from
///   where it started. Arms when off, disarms when on.
/// - Armed: `armedUntil` is `armedWindow` after the last frame seen while
///   armed, so fingers on the trackpad (and each step) keep it on; a frame
///   past it disarms (`expired`) before it counts, and `expire()` is the
///   session's timer for when no frame comes.
/// - Stroke: `strokeFingers` landing from a lift start it; at
///   `stepDistance` of travel on the dominant axis (at least
///   `GestureRecognizerSettings.verticalDominance` times the other one) it
///   fires one step; a diagonal, or any other finger count, consumes it.
///   Either way the fingers must lift (fewer than two) before the next one.
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
    /// TG-11: default travel (normalized units, a fifth of the trackpad)
    /// before a stroke steps; 0.1 fired too early on a real trackpad.
    public static let defaultStepDistance = 0.2

    /// Travel before a stroke steps (`[gestures] tap-to-swipe-distance`);
    /// a change applies from the next frame.
    public var stepDistance: Double

    private enum Tap: Sendable {
        case none
        case candidate(start: TimeInterval, origin: CGPoint)
        case spoiled
    }

    private enum Stroke: Sendable {
        /// Fingers lifted: the next two-finger frame starts a stroke.
        case ready
        /// Waiting for fewer than two fingers (a step fired, a diagonal, another count).
        case lifting
        case tracking(origin: CGPoint)
    }

    public private(set) var armedUntil: TimeInterval?
    private var tap = Tap.none
    private var stroke = Stroke.lifting

    public init(stepDistance: Double = defaultStepDistance) {
        self.stepDistance = stepDistance
    }

    public var isArmed: Bool {
        armedUntil != nil
    }

    public mutating func feed(_ frame: TouchFrame) -> [TapToSwipeEvent] {
        var events: [TapToSwipeEvent] = []
        if let until = armedUntil, frame.timestamp > until {
            armedUntil = nil
            events.append(.disarmed(.expired))
        }
        let count = frame.contacts.count
        if trackTap(frame) {
            if isArmed {
                armedUntil = nil
                events.append(.disarmed(.tap))
                return events
            }
            events.append(.armed)
            stroke = count < Self.strokeFingers ? .ready : .lifting
            armedUntil = frame.timestamp + Self.armedWindow
            return events
        }
        if isArmed {
            if let direction = trackStroke(frame) {
                events.append(.step(direction))
            }
            armedUntil = frame.timestamp + Self.armedWindow
        }
        return events
    }

    /// The session's timer: the window passed with no frame.
    public mutating func expire() -> [TapToSwipeEvent] {
        disarm(.expired)
    }

    public mutating func disarm(_ reason: TapToSwipeDisarm) -> [TapToSwipeEvent] {
        guard isArmed else {
            return []
        }
        armedUntil = nil
        return [.disarmed(reason)]
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
            tap = .candidate(start: frame.timestamp, origin: frame.centroid)
        case .candidate(let start, let origin):
            if frame.timestamp - start > Self.maxTapDuration || distance(frame.centroid, origin) > Self.maxTapTravel {
                tap = .spoiled
            }
        case .spoiled:
            break
        }
        return false
    }

    private mutating func trackStroke(_ frame: TouchFrame) -> TapSwipeDirection? {
        let count = frame.contacts.count
        guard count >= Self.strokeFingers else {
            stroke = .ready
            return nil
        }
        guard count == Self.strokeFingers else {
            stroke = .lifting
            return nil
        }
        switch stroke {
        case .ready:
            stroke = .tracking(origin: frame.centroid)
            return nil
        case .lifting:
            return nil
        case .tracking(let origin):
            let dx = Double(frame.centroid.x - origin.x)
            let dy = Double(frame.centroid.y - origin.y)
            let major = max(abs(dx), abs(dy))
            guard major >= stepDistance else {
                return nil
            }
            stroke = .lifting
            let minor = min(abs(dx), abs(dy))
            guard major >= GestureRecognizerSettings.verticalDominance * minor else {
                return nil
            }
            if abs(dx) >= abs(dy) {
                return dx < 0 ? .left : .right
            }
            return dy > 0 ? .up : .down
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// TG-10: the action a step runs. Natural (content follows the fingers):
/// swiping left shows the window on the right (`focus-right`); vertical
/// steps map like the workspace swipe (`workspaceSwipeAction`).
public func tapSwipeAction(_ direction: TapSwipeDirection, natural: Bool) -> HotkeyAction {
    switch direction {
    case .left:
        return natural ? .focusRight : .focusLeft
    case .right:
        return natural ? .focusLeft : .focusRight
    case .up:
        return workspaceSwipeAction(.up, natural: natural)
    case .down:
        return workspaceSwipeAction(.down, natural: natural)
    }
}
