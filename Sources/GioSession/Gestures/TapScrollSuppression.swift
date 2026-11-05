import Foundation

/// TG-10: whether the scroll-suppression tap swallows scroll events, so the
/// two-finger strokes of an armed tap-to-swipe neither scroll the app
/// underneath nor swipe a browser back. The session queue sets the deadline
/// (system uptime, `GestureController`'s clock); the tap thread reads it for
/// every scroll event, so the answer is one lock and a comparison. TG-12:
/// `suppress` says when armed flips, so the host enables the scroll tap on
/// arming and disables it on disarming, not on every renewal.
public final class TapScrollSuppression: @unchecked Sendable {
    /// Guards `until` (tap thread vs session queue).
    private let lock = NSLock()
    private var until: TimeInterval?

    public init() {}

    /// A deadline is set (it may have passed): a click should disarm.
    public var isArmed: Bool {
        lock.withLock { until != nil }
    }

    /// Session queue: swallow scrolling until `deadline`; nil stops. True
    /// when that turned suppression on or off.
    @discardableResult
    public func suppress(until deadline: TimeInterval?) -> Bool {
        lock.withLock {
            let flipped = (until == nil) != (deadline == nil)
            until = deadline
            return flipped
        }
    }

    /// Tap thread, per scroll event.
    public func swallows(at now: TimeInterval) -> Bool {
        lock.withLock { until.map { now <= $0 } ?? false }
    }
}
