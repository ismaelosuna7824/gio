import Darwin
import Foundation

/// Plan §21 single-instance guard: the session host takes this lock at
/// startup so a second WM can never boot by accident. Plain `flock` on a
/// file — no daemons, no sockets, no cleanup rituals. The daemon takes it;
/// the CLI never needs it.
public final class SingleInstanceLock {
    private var fd: Int32 = -1

    public init() {}

    /// True when the lock is ours. False when another process holds it or
    /// the file cannot be opened. Creates the parent directory so first
    /// boot with no config dir still locks.
    public func acquire(
        path: String, wait: LockWait = .none,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        acquiring(wait: wait, sleep: sleep) { tryAcquire(path: path) }
    }

    private func tryAcquire(path: String) -> Bool {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        fd = descriptor
        return true
    }

    public func release() {
        guard fd >= 0 else {
            return
        }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}

public func defaultLockPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/gio.lock"
}

/// Argument the restarting instance hands its successor: the old one may still
/// hold the lock for a moment while it restores windows and exits.
public let relaunchArgument = "--after-restart"

/// How long to keep trying for the single-instance lock.
public struct LockWait: Equatable, Sendable {
    public var attempts: Int
    public var interval: TimeInterval

    public init(attempts: Int, interval: TimeInterval) {
        self.attempts = max(1, attempts)
        self.interval = interval
    }

    /// One try, no waiting: an ordinary launch next to a live instance fails fast.
    public static let none = LockWait(attempts: 1, interval: 0)
    /// About five seconds, for the instance started by `gio restart`.
    public static let afterRestart = LockWait(attempts: 50, interval: 0.1)

    public static func forLaunch(arguments: [String]) -> LockWait {
        arguments.contains(relaunchArgument) ? .afterRestart : .none
    }
}

/// Try `attempt` up to `wait.attempts` times, sleeping between tries (never
/// after the last one).
public func acquiring(
    wait: LockWait, sleep: (TimeInterval) -> Void, attempt: () -> Bool
) -> Bool {
    for index in 0..<wait.attempts {
        if attempt() {
            return true
        }
        if index < wait.attempts - 1 {
            sleep(wait.interval)
        }
    }
    return false
}
