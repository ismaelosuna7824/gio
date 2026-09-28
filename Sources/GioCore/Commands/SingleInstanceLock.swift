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
    public func acquire(path: String) -> Bool {
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
