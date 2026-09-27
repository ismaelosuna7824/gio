import ApplicationServices
import Foundation
import GioCore

public enum AXWindowError: Error {
    case permissionDenied
    case unsupportedWindow
    case accessibility(AXError)
}

/// Callers supply a PID and AX window element obtained from public Accessibility APIs.
/// AX window elements have no stable public system-wide window ID; retain the element as the handle.
public final class AXWindowBridge: WorkspaceWindowBridge {
    public typealias Handle = AXUIElement
    private var windows: [WindowID: AXUIElement] = [:]

    public init() {}

    public func register(_ id: WindowID, element: AXUIElement) throws {
        try checkPermission()
        _ = try frame(of: element)
        windows[id] = element
    }

    /// Release a handle only after the owner has definitely terminated.
    public func forgetTerminatedWindow(_ id: WindowID) {
        windows.removeValue(forKey: id)
    }

    /// Only invalidUIElement proves a retained window handle is gone; all other errors remain uncertain.
    public func isDefinitelyInvalid(_ id: WindowID) throws -> Bool {
        try checkPermission()
        guard let element = windows[id] else { throw AXWindowError.unsupportedWindow }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        if result == .invalidUIElement { return true }
        guard result == .success else { throw AXWindowError.accessibility(result) }
        return false
    }

    public func checkPermission() throws {
        guard AXIsProcessTrusted() else { throw AXWindowError.permissionDenied }
    }

    public func capture(_ window: WindowID) throws -> (handle: AXUIElement, frame: CGRect) {
        try checkPermission()
        guard let element = windows[window] else { throw AXWindowError.unsupportedWindow }
        return (element, try frame(of: element))
    }

    public func frame(of handle: AXUIElement) throws -> CGRect {
        try checkPermission()
        var position: CFTypeRef?
        var size: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(handle, kAXPositionAttribute as CFString, &position)
        guard positionResult == .success else { throw AXWindowError.accessibility(positionResult) }
        let sizeResult = AXUIElementCopyAttributeValue(handle, kAXSizeAttribute as CFString, &size)
        guard sizeResult == .success else { throw AXWindowError.accessibility(sizeResult) }
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetType(position as! AXValue) == .cgPoint,
              AXValueGetType(size as! AXValue) == .cgSize else { throw AXWindowError.unsupportedWindow }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { throw AXWindowError.unsupportedWindow }
        return CGRect(origin: point, size: dimensions)
    }

    public func move(_ handle: AXUIElement, to origin: CGPoint) throws {
        try checkPermission()
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { throw AXWindowError.unsupportedWindow }
        let result = AXUIElementSetAttributeValue(handle, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw AXWindowError.accessibility(result) }
        let actual = try frame(of: handle).origin
        guard abs(actual.x - origin.x) <= 1 && abs(actual.y - origin.y) <= 1 else {
            throw AXWindowError.unsupportedWindow
        }
    }
}
