import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// Typed failures for single-window actions. Every case names the stage so a
/// live retest can report exactly what macOS refused. The reconciler (Phase 8)
/// will reuse these errors instead of inventing its own.
public enum SystemWindowActionError: Error, CustomStringConvertible {
    case permissionDenied
    case badIndex(requested: Int, count: Int)
    case appNotRunning(pid: pid_t)
    case notSettable(attribute: String)
    case writeFailed(attribute: String, status: AXError)
    case readbackFailed(attribute: String, status: AXError)
    case focusRefused(pid: pid_t)
    case frameMismatch(requested: CGRect, actual: CGRect)

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
        case .frameMismatch(let requested, let actual):
            return "frameMismatch: requested=\(describeFrame(requested)) actual=\(describeFrame(actual))"
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

/// Activate the app and ask macOS to focus this window. Throws `focusRefused`
/// when the window does not become focused.
public func focusSystemWindow(_ target: DiscoveredSystemWindow) throws {
    try actionAXPermission()
    guard let app = NSRunningApplication(processIdentifier: target.window.pid) else {
        throw SystemWindowActionError.appNotRunning(pid: target.window.pid)
    }
    app.activate()
    let status = AXUIElementSetAttributeValue(
        target.appElement, kAXFocusedWindowAttribute as CFString, target.element
    )
    guard status == .success else {
        throw SystemWindowActionError.focusRefused(pid: target.window.pid)
    }
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        target.appElement, kAXFocusedWindowAttribute as CFString, &raw
    ) == .success,
        let focused = raw,
        CFGetTypeID(focused) == AXUIElementGetTypeID(),
        CFEqual(focused as! AXUIElement, target.element)
    else {
        throw SystemWindowActionError.focusRefused(pid: target.window.pid)
    }
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
