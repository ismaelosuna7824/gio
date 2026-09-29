import Foundation

/// FI-06: rapid keyboard actions update logical state at once, but while a
/// motion is in flight the reflow that retargets it runs at most once per
/// motion tick instead of once per action. Session queue only; no locking.
public struct ReflowCoalescer: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// No motion in flight: reflow now.
        case runNow
        /// A motion is running: the next tick performs one merged reflow.
        case deferToTick
    }

    private var pending = false

    public init() {}

    public mutating func request(motionActive: Bool) -> Decision {
        guard motionActive else {
            pending = false
            return .runNow
        }
        pending = true
        return .deferToTick
    }

    /// True once per burst: the tick should run the merged reflow.
    public mutating func takeAtTick() -> Bool {
        defer { pending = false }
        return pending
    }

    public mutating func reset() {
        pending = false
    }
}
