import ApplicationServices
import Foundation
import GioCore

public enum AXWindowError: Error {
    public enum Stage: String, Sendable {
        case roleRead, positionRead, sizeRead, positionSettable, positionWrite
    }
    case permissionDenied
    case unsupportedWindow
    case invalidGeometry(Stage)
    case positionNotSettable
    case positionMismatch(requested: CGPoint, actual: CGPoint)
    case positionVerificationFailed(Error)
    case accessibility(stage: Stage, error: AXError)
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
        guard result == .success else { throw AXWindowError.accessibility(stage: .roleRead, error: result) }
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
        guard positionResult == .success else { throw AXWindowError.accessibility(stage: .positionRead, error: positionResult) }
        let sizeResult = AXUIElementCopyAttributeValue(handle, kAXSizeAttribute as CFString, &size)
        guard sizeResult == .success else { throw AXWindowError.accessibility(stage: .sizeRead, error: sizeResult) }
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetType(position as! AXValue) == .cgPoint else {
            throw AXWindowError.invalidGeometry(.positionRead)
        }
        var point = CGPoint.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXGeometryValidation.isValidPosition(point) else {
            throw AXWindowError.invalidGeometry(.positionRead)
        }
        guard let size, CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetType(size as! AXValue) == .cgSize else {
            throw AXWindowError.invalidGeometry(.sizeRead)
        }
        var dimensions = CGSize.zero
        guard AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              AXGeometryValidation.isValidSize(dimensions) else {
            throw AXWindowError.invalidGeometry(.sizeRead)
        }
        return CGRect(origin: point, size: dimensions)
    }

    public func move(_ handle: AXUIElement, to origin: CGPoint) throws {
        try checkPermission()
        guard origin.x.isFinite && origin.y.isFinite else { throw AXWindowError.invalidGeometry(.positionWrite) }
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(handle, kAXPositionAttribute as CFString, &settable)
        guard settableResult == .success else {
            throw AXWindowError.accessibility(stage: .positionSettable, error: settableResult)
        }
        guard settable.boolValue else { throw AXWindowError.positionNotSettable }
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { throw AXWindowError.invalidGeometry(.positionWrite) }
        let result = AXUIElementSetAttributeValue(handle, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw AXWindowError.accessibility(stage: .positionWrite, error: result) }
        let actual: CGPoint
        do { actual = try frame(of: handle).origin }
        catch { throw AXWindowError.positionVerificationFailed(error) }
        guard AXGeometryValidation.matches(requested: origin, actual: actual) else {
            throw AXWindowError.positionMismatch(requested: origin, actual: actual)
        }
    }
}
