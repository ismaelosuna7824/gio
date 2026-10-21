import Foundation

/// Per-pid display names for logs and timings. Resolving a name can be an
/// AppKit round trip, so it happens at most once per pid (lazily, off the
/// per-write path) and is dropped when the pid goes away.
public final class AppNameCache: @unchecked Sendable {
    private let resolve: @Sendable (pid_t) -> String?
    private let lock = NSLock()
    private var names: [pid_t: String] = [:]

    public init(resolve: @escaping @Sendable (pid_t) -> String? = { _ in nil }) {
        self.resolve = resolve
    }

    /// The app name, or `pid<N>` when it cannot be resolved. Only a resolved
    /// name is kept: an unreadable one is asked again next time, so callers
    /// that key learned state by name never stay on the placeholder.
    public func display(_ pid: pid_t) -> String {
        if let known = lock.withLock({ names[pid] }) {
            return known
        }
        guard let name = resolve(pid) else {
            return "pid\(pid)"
        }
        lock.withLock { names[pid] = name }
        return name
    }

    public func forget(_ pid: pid_t) {
        _ = lock.withLock { names.removeValue(forKey: pid) }
    }
}
