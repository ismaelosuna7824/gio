import CoreGraphics
import Foundation

/// Plan §24 easing. Small closed set: linear for tests and debugging,
/// ease-out for moves and resizes, ease-in-out for scrolls and workspace
/// slides. New curves arrive as cases, never as magic constants at call
/// sites.
public enum AnimationEasing: Equatable, Sendable {
    case linear
    case easeOut
    case easeInOut
}

/// Eased progress in [0, 1]. Non-finite input maps to zero — animations
/// degrade to their start frame, never to NaN geometry.
public func eased(_ progress: Double, easing: AnimationEasing) -> Double {
    guard progress.isFinite else {
        return 0
    }
    let clamped = min(max(progress, 0), 1)
    switch easing {
    case .linear:
        return clamped
    case .easeOut:
        return 1 - pow(1 - clamped, 3)
    case .easeInOut:
        if clamped < 0.5 {
            return 4 * clamped * clamped * clamped
        }
        return 1 - pow(-2 * clamped + 2, 3) / 2
    }
}

/// Raw linear interpolation with clamped progress. Callers ease first via
/// `eased` — this function never does.
public func lerp(_ from: CGFloat, _ to: CGFloat, progress: Double) -> CGFloat {
    let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
    return from + (to - from) * CGFloat(clamped)
}

/// PA-06: when a window's size follows its flight. `.none` is FI-03 (a grow
/// waits for the final pass); `.fromStart` interpolates from the first frame;
/// `.from(t0)` holds the old size until the fraction `t0` (0..1) of the flight
/// and reaches the target exactly at the end. Shrinks always land on the first
/// frame, whatever the schedule. `.atStart` (focused-grow) writes the final
/// size in the first frame, once, and only the origin flies afterwards: the
/// size never interpolates, so the app relays out a single time.
public enum SizeSchedule: Equatable, Sendable {
    case none
    case fromStart
    case from(Double)
    case atStart

    /// True when the size follows the flight frame by frame (PA-06).
    public var interpolates: Bool {
        switch self {
        case .fromStart, .from:
            return true
        case .none, .atStart:
            return false
        }
    }
}

/// One window's flight from one logical frame to the next. Covers movement,
/// resize, scroll and workspace slides — all are rect interpolation. Focus
/// changes apply instantly at the logical level; any highlight is a future
/// view concern, not state.
///
/// Deterministic by design: the caller passes elapsed time (the future
/// player samples per display frame). No clocks, no timers in Core — the
/// animation never feeds back into logical state, only into actuator writes.
public struct WindowAnimation: Equatable, Sendable {
    public var id: WindowID
    public var from: CGRect
    public var to: CGRect
    public var duration: Double
    public var easing: AnimationEasing
    /// NF-04: when set, a spring drives the flight instead of `easing`, and
    /// `duration` is the time the spring needs to settle (hard-capped).
    public var spring: SpringParameters?
    /// Origin velocity (points per second) the spring starts with: what a
    /// retarget inherits from the flight it interrupts.
    public var velocity: CGPoint
    /// PA-06: whether (and from when) the size interpolates during flight.
    public var sizeSchedule: SizeSchedule = .none

    public init(
        id: WindowID, from: CGRect, to: CGRect,
        duration: Double, easing: AnimationEasing = .easeOut
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.duration = duration
        self.easing = easing
        self.spring = nil
        self.velocity = .zero
    }

    /// A spring flight; `duration` is derived from the spring settling.
    public init(
        id: WindowID, from: CGRect, to: CGRect,
        spring: SpringParameters, velocity: CGPoint = .zero
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.easing = .easeOut
        self.spring = spring
        self.velocity = velocity
        self.duration = 0
        self.duration = settleDuration()
    }

    /// The same flight driven by `spring` (keeps endpoints, drops easing).
    public func springing(_ spring: SpringParameters, velocity: CGPoint = .zero) -> WindowAnimation {
        var result = WindowAnimation(id: id, from: from, to: to, spring: spring, velocity: velocity)
        result.sizeSchedule = sizeSchedule
        return result
    }

    private func settleDuration() -> Double {
        guard let spring else {
            return duration
        }
        return spring.settleTime(axes: [
            (Double(from.origin.x - to.origin.x), Double(velocity.x)),
            (Double(from.origin.y - to.origin.y), Double(velocity.y)),
        ])
    }

    /// Origin velocity in points per second at `elapsed` (zero once settled
    /// and for easing flights, which are retargeted from rest).
    public func velocity(at elapsed: Double) -> CGPoint {
        guard let spring, elapsed.isFinite else {
            return .zero
        }
        if elapsed < 0 {
            return velocity
        }
        guard elapsed < duration else {
            return .zero
        }
        func axis(_ from: CGFloat, _ to: CGFloat, _ velocity: CGFloat) -> CGFloat {
            CGFloat(spring.state(
                displacement: Double(from - to), velocity: Double(velocity), at: elapsed
            ).velocity)
        }
        return CGPoint(
            x: axis(from.origin.x, to.origin.x, velocity.x),
            y: axis(from.origin.y, to.origin.y, velocity.y)
        )
    }

    /// Frame at `elapsed` seconds. Zero or negative durations complete
    /// instantly; past-duration samples pin to `to`.
    public func frame(at elapsed: Double) -> CGRect {
        if let spring {
            return springFrame(spring, at: elapsed)
        }
        guard duration > 0, elapsed.isFinite else {
            return elapsed.isFinite && elapsed < 0 ? from : to
        }
        let progress = eased(elapsed / duration, easing: easing)
        return CGRect(
            x: lerp(from.origin.x, to.origin.x, progress: progress),
            y: lerp(from.origin.y, to.origin.y, progress: progress),
            width: lerp(from.size.width, to.size.width, progress: progress),
            height: lerp(from.size.height, to.size.height, progress: progress)
        )
    }

    private func springFrame(_ spring: SpringParameters, at elapsed: Double) -> CGRect {
        guard elapsed.isFinite else {
            return to
        }
        if elapsed < 0 {
            return from
        }
        if elapsed >= duration {
            return to
        }
        func axis(_ from: CGFloat, _ to: CGFloat, _ velocity: CGFloat) -> CGFloat {
            to + CGFloat(spring.state(
                displacement: Double(from - to), velocity: Double(velocity), at: elapsed
            ).displacement)
        }
        return CGRect(
            x: axis(from.origin.x, to.origin.x, velocity.x),
            y: axis(from.origin.y, to.origin.y, velocity.y),
            width: axis(from.size.width, to.size.width, 0),
            height: axis(from.size.height, to.size.height, 0)
        )
    }

    /// Origin progress in [0, 1] at `elapsed`: the eased fraction for easing
    /// flights; for springs, how much of the dominant travel axis is covered
    /// (`1 - x(t) / x(0)`, clamped, so overshoot reads as arrived). A flight
    /// with no origin travel falls back to plain ease-out over `duration`.
    /// Size schedules follow this, so a size lands with the position.
    public func normalizedProgress(at elapsed: Double) -> Double {
        guard elapsed.isFinite else {
            return 1
        }
        if elapsed <= 0 {
            return 0
        }
        if elapsed >= duration {
            return 1
        }
        if let spring {
            let dx = Double(from.origin.x - to.origin.x), dy = Double(from.origin.y - to.origin.y)
            guard max(abs(dx), abs(dy)) >= 1 else {
                return eased(elapsed / duration, easing: .easeOut)
            }
            let horizontal = abs(dx) >= abs(dy)
            let start = horizontal ? dx : dy
            let now = spring.state(
                displacement: start, velocity: Double(horizontal ? velocity.x : velocity.y), at: elapsed
            ).displacement
            return min(max(1 - now / start, 0), 1)
        }
        return eased(elapsed / duration, easing: easing)
    }

    /// Size progress in [0, 1] under `sizeSchedule`.
    func sizeProgress(at elapsed: Double) -> Double {
        let start: Double
        switch sizeSchedule {
        case .none:
            return 0
        case .atStart:
            return elapsed.isFinite && elapsed < 0 ? 0 : 1
        case .fromStart:
            start = 0
        case .from(let fraction):
            start = min(max(fraction, 0), 1)
        }
        guard elapsed.isFinite, elapsed < duration else {
            return 1
        }
        if start == 0 {
            return normalizedProgress(at: elapsed)
        }
        if elapsed < start * duration {
            return 0
        }
        let base = normalizedProgress(at: start * duration)
        guard base < 1 else {
            return 1
        }
        return min(max((normalizedProgress(at: elapsed) - base) / (1 - base), 0), 1)
    }

    /// The frame a window is actually WRITTEN during motion (FI-03): the
    /// origin follows `frame(at:)`. A dimension that shrinks takes its new
    /// value from the first frame (the window gets out of its neighbours' way
    /// before anything moves). A dimension that grows keeps its old value all
    /// the way, including at completion, so the final exact pass applies it
    /// once the neighbours have moved, UNLESS `sizeSchedule` (PA-06) lets it
    /// interpolate because the app keeps up and nothing is in the way. Frames
    /// after the first are then position-only (one Accessibility write per
    /// window) or, for a scheduled grow, position and size. `frame(at:)` stays
    /// the full interpolation, for callers that want the ideal frame.
    public func motionFrame(at elapsed: Double) -> CGRect {
        let full = frame(at: elapsed)
        guard duration > 0 else {
            return full
        }
        let progress = sizeProgress(at: elapsed)
        func dimension(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            to > from ? lerp(from, to, progress: progress) : min(from, to)
        }
        return CGRect(
            origin: full.origin,
            size: CGSize(
                width: dimension(from.size.width, to.size.width),
                height: dimension(from.size.height, to.size.height)
            )
        )
    }

    public func isComplete(at elapsed: Double) -> Bool {
        !elapsed.isFinite || elapsed >= duration
    }
}
