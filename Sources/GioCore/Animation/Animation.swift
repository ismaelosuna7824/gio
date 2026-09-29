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

    public init(
        id: WindowID, from: CGRect, to: CGRect,
        duration: Double, easing: AnimationEasing = .easeOut
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.duration = duration
        self.easing = easing
    }

    /// Frame at `elapsed` seconds. Zero or negative durations complete
    /// instantly; past-duration samples pin to `to`.
    public func frame(at elapsed: Double) -> CGRect {
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

    /// The frame a window is actually WRITTEN during motion (FI-03): the
    /// origin follows `frame(at:)`, but the size never interpolates. A
    /// dimension that shrinks takes its new value from the first frame (the
    /// window gets out of its neighbours' way before anything moves), and a
    /// dimension that grows keeps its old value all the way, including at
    /// completion; the final exact pass applies it once the neighbours have
    /// moved. Every frame after the first is therefore position-only (one
    /// Accessibility write per window). `frame(at:)` stays the full
    /// interpolation, for callers that want the ideal frame.
    public func motionFrame(at elapsed: Double) -> CGRect {
        let full = frame(at: elapsed)
        guard duration > 0 else {
            return full
        }
        return CGRect(
            origin: full.origin,
            size: CGSize(
                width: min(from.size.width, to.size.width),
                height: min(from.size.height, to.size.height)
            )
        )
    }

    public func isComplete(at elapsed: Double) -> Bool {
        !elapsed.isFinite || elapsed >= duration
    }
}
