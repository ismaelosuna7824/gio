import Foundation

/// TG-10: whether the hotkey tap swallows scroll events, so the two-finger
/// strokes of an armed tap-to-swipe neither scroll the app underneath nor
/// swipe a browser back. The session queue sets the deadline (system
/// uptime, `GestureController`'s clock) and the config flag; the tap thread
/// reads them for every scroll event, so the answer is one lock and a
/// comparison.
public final class TapScrollSuppression: @unchecked Sendable {
    /// Guards `enabled` and `until` (tap thread vs session queue vs main).
    private let lock = NSLock()
    private var enabled = false
    private var until: TimeInterval?

    public init() {}

    /// `[gestures] tap-to-swipe`: the tap subscribes to scroll events only
    /// while this is on.
    public var isEnabled: Bool {
        get {
            lock.withLock { enabled }
        }
        set {
            lock.withLock { enabled = newValue }
        }
    }

    /// A deadline is set (it may have passed): a click should disarm.
    public var isArmed: Bool {
        lock.withLock { until != nil }
    }

    /// Session queue: swallow scrolling until `deadline`; nil stops.
    public func suppress(until deadline: TimeInterval?) {
        lock.withLock { until = deadline }
    }

    /// Tap thread, per scroll event.
    public func swallows(at now: TimeInterval) -> Bool {
        lock.withLock { until.map { now <= $0 } ?? false }
    }
}
