import CoreGraphics
import Foundation

/// SM-01: Screen Recording permission, needed by the snapshot renderer
/// (ScreenCaptureKit). Compile-checked only: the system calls are thin.

/// Read-only check. Never prompts, so it is safe to poll.
public func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
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
