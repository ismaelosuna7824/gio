import Foundation

/// Nothing moves under the cursor: while a mouse button is down a reflow is
/// deferred and retried until release. Requests made meanwhile coalesce into
/// the single pending retry. Pure state machine; the host feeds it the
/// button state and owns the timer.
public struct ReflowDeferral: Sendable {
    public enum Step: Equatable, Sendable {
        /// Run the reflow now.
        case apply
        /// Start polling: check again after this delay.
        case poll(after: TimeInterval)
        /// A poll is already scheduled; this request is folded into it.
        case alreadyPolling
    }

    public static let pollInterval: TimeInterval = 0.05

    private var isPolling = false

    public init() {}

    /// A reflow wants to run.
    public mutating func request(mouseDown: Bool) -> Step {
        guard mouseDown else {
            return .apply
        }
        if isPolling {
            return .alreadyPolling
        }
        isPolling = true
        return .poll(after: Self.pollInterval)
    }

    /// The scheduled poll fired: run the one coalesced reflow once released.
    public mutating func poll(mouseDown: Bool) -> Step {
        if mouseDown {
            return .poll(after: Self.pollInterval)
        }
        isPolling = false
        return .apply
    }
}
