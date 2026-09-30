import Foundation

/// NW-06: why an arrival took the user to its named workspace.
public enum ArrivalFollowReason: String, Equatable, Sendable {
    /// `follow = "always"`.
    case always
    /// The window's app was frontmost as the window appeared.
    case frontmost
    /// The window's app was launched moments before (not frontmost yet).
    case launched
    /// The window's app became active shortly after the window was placed.
    case activated
}

/// NW-06: what a live arrival does about following, decided at registration.
public enum ArrivalFollowDecision: Equatable, Sendable {
    case follow(ArrivalFollowReason)
    /// `when-active`, app neither frontmost nor freshly launched: placed
    /// silently, but follows if the app becomes active soon.
    case pending
    /// `never`.
    case stay
}

/// NW-06: the time windows of the `when-active` follow policy.
public enum ArrivalFollowTiming {
    /// An app launched this recently counts as the user's (it often opens
    /// its first window before it is frontmost).
    public static let launchWindow: TimeInterval = 3
    /// A placed window follows when its app becomes active this soon after.
    public static let activationWindow: TimeInterval = 1.5
}

/// NW-06: `always` follows, `never` stays; `when-active` follows when the
/// app is frontmost or was launched within `launchWindow`, else it waits
/// for an activation (`PendingFollowBook`). Only for live arrivals: a
/// startup or rescan never asks.
public func decideArrivalFollow(
    _ policy: WorkspaceFollowPolicy, windowPID: pid_t, frontmostPID: pid_t?,
    launchedAt: TimeInterval?, now: TimeInterval
) -> ArrivalFollowDecision {
    switch policy {
    case .always:
        return .follow(.always)
    case .never:
        return .stay
    case .whenActive:
        if frontmostPID == windowPID {
            return .follow(.frontmost)
        }
        if let launchedAt, now >= launchedAt, now - launchedAt <= ArrivalFollowTiming.launchWindow {
            return .follow(.launched)
        }
        return .pending
    }
}

/// NW-06: apps launched in the last `launchWindow` seconds, by pid.
public struct RecentLaunches: Sendable {
    private var launches: [pid_t: TimeInterval] = [:]

    public init() {}

    public var count: Int { launches.count }

    public mutating func record(_ pid: pid_t, at time: TimeInterval) {
        launches = launches.filter { time - $0.value <= ArrivalFollowTiming.launchWindow }
        launches[pid] = time
    }

    /// The launch time when it is still recent at `now`, else nil.
    public func launchedAt(_ pid: pid_t, now: TimeInterval) -> TimeInterval? {
        guard let time = launches[pid], now - time <= ArrivalFollowTiming.launchWindow else {
            return nil
        }
        return time
    }
}

/// NW-06: a `when-active` arrival placed silently on a hidden named
/// workspace, remembered with where the user was at that moment.
public struct PendingArrivalFollow: Equatable, Sendable {
    public var id: WindowID
    /// The named workspace the window was placed on.
    public var workspace: WorkspaceID
    public var placedAt: TimeInterval
    /// The user's workspace and focus when the window was placed.
    public var fromWorkspace: WorkspaceID
    public var fromFocus: WindowID?

    public init(
        id: WindowID, workspace: WorkspaceID, placedAt: TimeInterval,
        fromWorkspace: WorkspaceID, fromFocus: WindowID?
    ) {
        self.id = id
        self.workspace = workspace
        self.placedAt = placedAt
        self.fromWorkspace = fromWorkspace
        self.fromFocus = fromFocus
    }
}

/// NW-06: pending follows, consumed by their app's activation within
/// `activationWindow`, dropped when they expire or their window closes.
public struct PendingFollowBook: Sendable {
    private var entries: [PendingArrivalFollow] = []

    public init() {}

    public var count: Int { entries.count }

    public mutating func add(_ pending: PendingArrivalFollow) {
        entries.removeAll { $0.id == pending.id }
        entries.append(pending)
    }

    /// The app `pid` became active: its newest pending follow still inside
    /// the window, if any. Every entry of that app and every expired entry
    /// is dropped either way (one activation follows at most once).
    public mutating func activated(pid: pid_t, now: TimeInterval) -> PendingArrivalFollow? {
        let live = entries.filter { now - $0.placedAt <= ArrivalFollowTiming.activationWindow }
        let match = live.filter { $0.id.pid == pid }.max { $0.placedAt < $1.placedAt }
        entries = live.filter { $0.id.pid != pid }
        return match
    }

    public mutating func forget(_ id: WindowID) {
        entries.removeAll { $0.id == id }
    }
}

/// NW-06: a pending follow still applies only while the user stayed on
/// the workspace, with the focus, they had when the window was placed.
public func pendingFollowStillWanted(
    _ pending: PendingArrivalFollow, currentWorkspace: WorkspaceID, currentFocus: WindowID?
) -> Bool {
    currentWorkspace == pending.fromWorkspace && currentFocus == pending.fromFocus
        && currentWorkspace != pending.workspace
}
