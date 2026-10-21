import CoreGraphics
import Foundation

/// SM-01: Screen Recording permission, needed by the snapshot renderer
/// (ScreenCaptureKit). Compile-checked only: the system calls are thin.

/// Read-only check. Never prompts. Each call is an IPC to tccd (~8 ms,
/// measured): hot paths use `ScreenRecordingPermissionCache`.
public func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
}

/// PF-X: the session asked for the permission several times per typing hop
/// and per capture run, ~8 ms on the session queue each. `granted()`
/// answers from the last check for `ttl`; `refresh()` asks now (PA-15b: the
/// facts the UI polls call it only while the answer is missing, so a grant
/// shows there at once and a revoke within `ttl`). Any thread.
public final class ScreenRecordingPermissionCache: @unchecked Sendable {
    public static let ttl: TimeInterval = 10

    private let check: () -> Bool
    private let now: () -> TimeInterval
    /// Guards `cached`.
    private let lock = NSLock()
    private var cached: (granted: Bool, at: TimeInterval)?

    public init(
        check: @escaping () -> Bool = hasScreenRecordingPermission,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.check = check
        self.now = now
    }

    public func granted() -> Bool {
        let time = now()
        lock.lock()
        let cached = cached
        lock.unlock()
        if let cached, time - cached.at < Self.ttl {
            return cached.granted
        }
        return refresh()
    }

    @discardableResult
    public func refresh() -> Bool {
        let granted = check()
        let time = now()
        lock.lock()
        cached = (granted, time)
        lock.unlock()
        return granted
    }
}

/// Asks macOS to show the Screen Recording dialog. Call on the main thread,
/// and only from an explicit user action (the "Request access" button): Gio
/// never requests it at launch. macOS usually applies a fresh grant only
/// after the app is relaunched, so the returned value can still be false.
@discardableResult
public func requestScreenRecordingPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() {
        return true
    }
    return CGRequestScreenCaptureAccess()
}
