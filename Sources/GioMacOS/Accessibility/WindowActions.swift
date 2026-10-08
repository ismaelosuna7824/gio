import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore

/// Typed failures for single-window actions. Every case names the stage so a
/// live retest can report exactly what macOS refused. The reconciler (Phase 8)
/// will reuse these errors instead of inventing its own.
public enum SystemWindowActionError: Error, CustomStringConvertible, FrameFailureReporting {
    case permissionDenied
    case badIndex(requested: Int, count: Int)
    case appNotRunning(pid: pid_t)
    case notSettable(attribute: String)
    case writeFailed(attribute: String, status: AXError)
    case readbackFailed(attribute: String, status: AXError)
    case focusRefused(pid: pid_t)
    /// PF-I: the focus call ran but another app (or none) stayed frontmost.
    /// `frontmostWrite` is the status of the `AXFrontmost` write.
    case notFrontmost(pid: pid_t, frontmost: pid_t?, frontmostWrite: AXError)
    case frameMismatch(requested: CGRect, actual: CGRect)
    case unknownHandle(elementID: UInt64)

    /// FI-01 kind for the reconcile failure log: stable, no titles.
    public var failureKind: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .badIndex: return "badIndex"
        case .appNotRunning: return "appNotRunning"
        case .notSettable(let attribute): return "notSettable(\(attribute))"
        case .writeFailed(let attribute, let status): return "writeFailed(\(attribute),\(status.rawValue))"
        case .readbackFailed(let attribute, let status): return "readbackFailed(\(attribute),\(status.rawValue))"
        case .focusRefused: return "focusRefused"
        case .notFrontmost(_, let frontmost, let write):
            return "notFrontmost(frontmost=\(frontmost.map(String.init) ?? "none"),ax=\(write.rawValue))"
        case .frameMismatch: return ReconcileFailure.frameMismatchKind
        case .unknownHandle: return "unknownHandle"
        }
    }

    public var failureActual: CGRect? {
        if case .frameMismatch(_, let actual) = self, actual != .zero {
            return actual
        }
        return nil
    }

    public var description: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied: enable the app under System Settings → Privacy & Security → Accessibility, then retry"
        case .badIndex(let requested, let count):
            return "badIndex: requested=\(requested) count=\(count)"
        case .appNotRunning(let pid):
            return "appNotRunning: pid=\(pid)"
        case .notSettable(let attribute):
            return "notSettable: attribute=\(attribute)"
        case .writeFailed(let attribute, let status):
            return "writeFailed: attribute=\(attribute) status=\(status.rawValue)"
        case .readbackFailed(let attribute, let status):
            return "readbackFailed: attribute=\(attribute) status=\(status.rawValue)"
        case .focusRefused(let pid):
            return "focusRefused: pid=\(pid)"
        case .notFrontmost(let pid, let frontmost, let write):
            return "notFrontmost: pid=\(pid) frontmost=\(frontmost.map(String.init) ?? "none") axFrontmostWrite=\(write.rawValue)"
        case .frameMismatch(let requested, let actual):
            return "frameMismatch: requested=\(describeFrame(requested)) actual=\(describeFrame(actual))"
        case .unknownHandle(let elementID):
            return "unknownHandle: elementID=\(elementID)"
        }
    }
}

func actionAXPermission() throws {
    do {
        try requireAXPermission()
    } catch {
        throw SystemWindowActionError.permissionDenied
    }
}

public func systemWindow(at index: Int, in windows: [DiscoveredSystemWindow]) throws
    -> DiscoveredSystemWindow
{
    guard index >= 0, index < windows.count else {
        throw SystemWindowActionError.badIndex(requested: index, count: windows.count)
    }
    return windows[index]
}

func checkSettable(_ element: AXUIElement, attribute: String) throws {
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    guard status == .success, settable.boolValue else {
        if status != .success {
            throw SystemWindowActionError.writeFailed(attribute: attribute, status: status)
        }
        throw SystemWindowActionError.notSettable(attribute: attribute)
    }
}

func readAXFrame(_ element: AXUIElement) throws -> CGRect {
    guard let frame = axFrame(of: element) else {
        throw SystemWindowActionError.readbackFailed(attribute: "position/size", status: .failure)
    }
    return frame
}

func framesMatch(_ requested: CGRect, _ actual: CGRect) -> Bool {
    abs(requested.origin.x - actual.origin.x) <= 1
        && abs(requested.origin.y - actual.origin.y) <= 1
        && abs(requested.size.width - actual.size.width) <= 1
        && abs(requested.size.height - actual.size.height) <= 1
}

/// Activate the app and ask macOS to focus this window. Throws when the app
/// does not become frontmost (`notFrontmost`) or keeps another window focused
/// (`focusRefused`).
public func focusSystemWindow(_ target: DiscoveredSystemWindow) throws {
    try actionAXPermission()
    // A CLI's main thread runs no run loop on its own: spin it while waiting
    // so `NSWorkspace` sees the activation (properties refresh per main
    // run-loop turn). The app never focuses from main.
    try focusAXWindow(
        appElement: target.appElement, element: target.element, pid: target.window.pid,
        wait: { delay in
            if Thread.isMainThread {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: delay))
            } else {
                Thread.sleep(forTimeInterval: delay)
            }
        }
    )
}

/// Shared focus primitive used by the CLI and the reconciler actuator.
///
/// PF-I: focus is the target's app frontmost with the target as its focused
/// window (`FocusLanding`). `NSRunningApplication.activate()` alone is a
/// request: with no option the app activates only when no other app is
/// active (documented), so an active unmanaged app (live: OrbStack) kept the
/// keyboard. The trusted Accessibility client therefore also writes the
/// app's `AXFrontmost` (the app makes itself active), after the window is
/// focused and raised so it is the one activation brings forward. Then the
/// bounded re-check (`FocusLandingCheck`, at most 50 ms) confirms it.
///
/// Runs on the calling thread: an app's write lane or the session queue,
/// never main (`wait` sleeps there). Off-main AppKit use: `NSRunningApplication`
/// is documented thread-safe; `activate()` and `NSWorkspace.frontmostApplication`
/// already ran on the session queue before SM-12. Gio's own pid never reaches
/// here (AGENTS rule 4), so no AX call runs AppKit in-process.
func focusAXWindow(
    appElement: AXUIElement, element: AXUIElement, pid: pid_t,
    wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) throws {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        throw SystemWindowActionError.appNotRunning(pid: pid)
    }
    app.activate()
    let status = AXUIElementSetAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, element
    )
    guard status == .success else {
        throw SystemWindowActionError.writeFailed(attribute: kAXFocusedWindowAttribute as String, status: status)
    }
    // Bring the window above its siblings; the landing check decides success.
    _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    let frontmostWrite = AXUIElementSetAttributeValue(
        appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue
    )
    var frontmost: pid_t?
    let landing = FocusLandingCheck.await(
        check: {
            frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return FocusLanding.judge(targetPID: pid, frontmostPID: frontmost) {
                appFocusedWindow(of: appElement, is: element)
            }
        },
        clock: { ProcessInfo.processInfo.systemUptime },
        wait: wait
    )
    switch landing {
    case .landed:
        return
    case .notFrontmost:
        throw SystemWindowActionError.notFrontmost(pid: pid, frontmost: frontmost, frontmostWrite: frontmostWrite)
    case .windowNotFocused:
        throw SystemWindowActionError.focusRefused(pid: pid)
    }
}

/// One AX read: whether the app's focused window is `element`.
private func appFocusedWindow(of appElement: AXUIElement, is element: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &raw
    ) == .success,
        let focused = raw,
        CFGetTypeID(focused) == AXUIElementGetTypeID()
    else {
        return false
    }
    return CFEqual(focused as! AXUIElement, element)
}

/// Move a window, then verify with readback. Returns the observed frame.
public func moveSystemWindow(_ target: DiscoveredSystemWindow, to point: CGPoint) throws -> CGRect {
    try actionAXPermission()
    try checkSettable(target.element, attribute: kAXPositionAttribute as String)
    var moving = point
    guard let value = AXValueCreate(.cgPoint, &moving) else {
        throw SystemWindowActionError.writeFailed(attribute: "position", status: .failure)
    }
    let status = AXUIElementSetAttributeValue(
        target.element, kAXPositionAttribute as CFString, value
    )
    guard status == .success else {
        throw SystemWindowActionError.writeFailed(attribute: "position", status: status)
    }
    let current = try readAXFrame(target.element)
    let requested = CGRect(origin: point, size: target.window.frame.size)
    guard framesMatch(requested, current) else {
        throw SystemWindowActionError.frameMismatch(requested: requested, actual: current)
    }
    return current
}

/// Resize a window, then verify with readback. Returns the observed frame.
public func resizeSystemWindow(_ target: DiscoveredSystemWindow, to size: CGSize) throws -> CGRect {
    try actionAXPermission()
    try checkSettable(target.element, attribute: kAXSizeAttribute as String)
    var resizing = size
    guard let value = AXValueCreate(.cgSize, &resizing) else {
        throw SystemWindowActionError.writeFailed(attribute: "size", status: .failure)
    }
    let status = AXUIElementSetAttributeValue(target.element, kAXSizeAttribute as CFString, value)
    guard status == .success else {
        throw SystemWindowActionError.writeFailed(attribute: "size", status: status)
    }
    let current = try readAXFrame(target.element)
    let requested = CGRect(origin: target.window.frame.origin, size: size)
    guard framesMatch(requested, current) else {
        throw SystemWindowActionError.frameMismatch(requested: requested, actual: current)
    }
    return current
}
