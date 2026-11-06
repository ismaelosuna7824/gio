import Foundation

/// FI-16: windows on screen that Gio never registered. A scan that met an
/// app whose Accessibility was not ready yet (just launched, or the screen
/// still unlocking) skips its windows or lists none; nothing used to ask
/// again. These are the timings of asking again.
public enum StrandedWindowRetry {
    /// Per-pid rescans after a skip or a stranded window, one after another.
    public static let delays: [TimeInterval] = [0.5, 1.5, 4, 10]
    /// The window server vs registry check runs on every full scan and at
    /// most this long apart otherwise.
    public static let auditInterval: TimeInterval = 30
    /// Full rescans after a wake or an unlock, besides the immediate one:
    /// the first often meets the unlocking screen, whose apps answer nothing.
    public static let wakeSettleDelays: [TimeInterval] = [2, 6]
}

public enum WindowRetryReason: String, Equatable, Sendable {
    /// A scan skipped windows of the pid (unreadable attributes).
    case skipped
    /// The window server lists an on-screen window of the pid no managed
    /// window has.
    case unregistered
}

/// One per-pid rescan to schedule: attempt `attempt` runs `delay` from now.
public struct WindowRetryStep: Equatable, Sendable {
    public let pid: pid_t
    public let attempt: Int
    public let delay: TimeInterval
    public let reason: WindowRetryReason

    public init(pid: pid_t, attempt: Int, delay: TimeInterval, reason: WindowRetryReason) {
        self.pid = pid
        self.attempt = attempt
        self.delay = delay
        self.reason = reason
    }
}

public enum WindowRetryOutcome: Equatable, Sendable {
    /// Read fully and nothing of it stranded: the series ends.
    case resolved
    /// The app is gone: the series ends, nothing is remembered.
    case appGone
    case retry(WindowRetryStep)
    /// The last attempt did not resolve it.
    case gaveUp(attempts: Int, reason: WindowRetryReason)
}

/// FI-16: the per-pid retry series. One series per pid; the attempt in
/// flight is the only one that may run (a stale timer finds it gone).
/// Giving up remembers the stranded numbers (`rejected`: admission refuses
/// them, or the app never answers) so the window server check does not
/// rescan them forever; a number the window server stops listing, or a
/// wake, forgets them. A skip series that gave up ignores further skips of
/// that pid until one of its scans reads it fully (an element that never
/// answers would restart it on every full scan). Pure, session queue.
public struct StrandedWindowRetryBook: Equatable, Sendable {
    private var series: [pid_t: Series] = [:]
    private var skipGaveUp: Set<pid_t> = []
    public private(set) var rejected: Set<UInt32> = []

    private struct Series: Equatable, Sendable {
        var attempt: Int
        var reason: WindowRetryReason
    }

    public init() {}

    /// The first step of a new series, or nil when one runs already (an
    /// unregistered request upgrades a skip series: a full read alone no
    /// longer resolves it) or the skip waits for a full read.
    public mutating func request(_ pid: pid_t, reason: WindowRetryReason) -> WindowRetryStep? {
        if var running = series[pid] {
            if reason == .unregistered {
                running.reason = .unregistered
                series[pid] = running
            }
            return nil
        }
        if reason == .skipped, skipGaveUp.contains(pid) {
            return nil
        }
        series[pid] = Series(attempt: 1, reason: reason)
        return step(pid, attempt: 1, reason: reason)
    }

    public func isPending(_ pid: pid_t, attempt: Int) -> Bool {
        series[pid]?.attempt == attempt
    }

    public func reason(of pid: pid_t) -> WindowRetryReason? {
        series[pid]?.reason
    }

    /// After attempt `attempt` of the pid: `resolved` when its latest scan
    /// read it fully and nothing of it is stranded; `stranded` its numbers
    /// still unregistered (remembered when giving up).
    public mutating func finish(
        _ pid: pid_t, attempt: Int, alive: Bool, resolved: Bool, stranded: Set<UInt32>
    ) -> WindowRetryOutcome {
        guard let running = series[pid], running.attempt == attempt else {
            return .resolved
        }
        guard alive else {
            series.removeValue(forKey: pid)
            skipGaveUp.remove(pid)
            return .appGone
        }
        if resolved {
            series.removeValue(forKey: pid)
            return .resolved
        }
        guard attempt < StrandedWindowRetry.delays.count else {
            series.removeValue(forKey: pid)
            rejected.formUnion(stranded)
            if running.reason == .skipped {
                skipGaveUp.insert(pid)
            }
            return .gaveUp(attempts: attempt, reason: running.reason)
        }
        series[pid] = Series(attempt: attempt + 1, reason: running.reason)
        return .retry(step(pid, attempt: attempt + 1, reason: running.reason))
    }

    /// A scan of the pid ended; a full read lets its skips ask again.
    public mutating func noteRead(_ pid: pid_t, complete: Bool) {
        if complete {
            skipGaveUp.remove(pid)
        }
    }

    /// Forget rejected numbers the window server no longer lists.
    public mutating func keepRejected(listed: Set<UInt32>) {
        rejected.formIntersection(listed)
    }

    /// A wake or unlock: what failed behind the lock may answer now.
    public mutating func clearRejected() {
        rejected.removeAll()
        skipGaveUp.removeAll()
    }

    private func step(_ pid: pid_t, attempt: Int, reason: WindowRetryReason) -> WindowRetryStep {
        WindowRetryStep(pid: pid, attempt: attempt, delay: StrandedWindowRetry.delays[attempt - 1], reason: reason)
    }
}

/// FI-16: the window server's on-screen layer-0 windows (`server`) that no
/// managed window has, per pid, numbers ascending. Only pids discovery
/// would scan (`manageablePIDs`: regular apps; never Gio's own, rule 4);
/// numberless entries cannot be compared and rejected numbers were given up.
public func strandedServerWindows(
    _ server: [ServerWindow], registeredNumbers: Set<UInt32>, ownPID: pid_t,
    manageablePIDs: Set<pid_t>, rejected: Set<UInt32>
) -> [pid_t: [UInt32]] {
    var stranded: [pid_t: [UInt32]] = [:]
    for window in server where window.pid != ownPID && manageablePIDs.contains(window.pid) {
        guard let number = window.number, !registeredNumbers.contains(number), !rejected.contains(number) else {
            continue
        }
        stranded[window.pid, default: []].append(number)
    }
    return stranded.mapValues { $0.sorted() }
}
