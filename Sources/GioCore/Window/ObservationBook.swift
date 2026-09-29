import Foundation

/// What to do with per-app event observers after comparing the running set
/// with the observed set.
public struct ObservationPlan: Equatable, Sendable {
    public let attach: [pid_t]
    public let detach: [pid_t]

    public init(attach: [pid_t], detach: [pid_t]) {
        self.attach = attach
        self.detach = detach
    }
}

/// Pure bookkeeping for incremental per-pid observation: which processes
/// have a live observer, which refused one. A refused pid is not retried by
/// `reconcile` (it would refuse again on every resync) but IS retried when
/// the app is activated or launched again, since AX readiness changes over
/// time. The host owns one and wires the attach/detach side effects.
public struct ObservationBook: Sendable {
    public private(set) var observed: Set<pid_t> = []
    public private(set) var refused: Set<pid_t> = []

    public init() {}

    /// Diff the running regular-app set against the book. Forgets refused
    /// pids that quit; refused pids still running are left for activation.
    public mutating func reconcile(running: Set<pid_t>) -> ObservationPlan {
        refused = refused.intersection(running)
        let attach = running.subtracting(observed).subtracting(refused)
        let detach = observed.subtracting(running)
        return ObservationPlan(attach: attach.sorted(), detach: detach.sorted())
    }

    /// True when an observer is missing: never attached, refused before, or
    /// detached. Used on launch and activation.
    public func needsAttach(_ pid: pid_t) -> Bool {
        !observed.contains(pid)
    }

    public mutating func didAttach(_ pid: pid_t) {
        observed.insert(pid)
        refused.remove(pid)
    }

    public mutating func didRefuse(_ pid: pid_t) {
        observed.remove(pid)
        refused.insert(pid)
    }

    public mutating func didDetach(_ pid: pid_t) {
        observed.remove(pid)
        refused.remove(pid)
    }
}

/// Backoff for attaching an observer to a freshly launched app: Accessibility
/// is often not ready in the first moments of a process.
public enum ObservationRetry {
    public static let delays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0]
    public static var maxRetries: Int { delays.count }

    /// Delay before the next attempt after `attempt` (0-based) failed, or nil
    /// when retries are exhausted.
    public static func delay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < delays.count else {
            return nil
        }
        return delays[attempt]
    }
}
