import ApplicationServices
import Foundation
import GioCore

public enum AXWindowError: Error {
    public enum Stage: String, Sendable {
        case roleRead, positionRead, sizeRead, positionSettable, positionWrite, sizeSettable, sizeWrite
    }
    case permissionDenied
    case unsupportedWindow
    case invalidGeometry(Stage)
    case positionNotSettable
    case sizeNotSettable
    case frameMismatch(requested: CGRect, actual: CGRect)
    case frameVerificationFailed(Error)
    case accessibility(stage: Stage, error: AXError)
}

extension AXWindowError: WindowFrameMismatch {
    public var mismatchedFrames: (requested: CGRect, actual: CGRect)? {
        guard case .frameMismatch(let requested, let actual) = self else { return nil }
        return (requested, actual)
    }
}

/// Callers supply a PID and AX window element obtained from public Accessibility APIs.
/// AX window elements have no stable public system-wide window ID; retain the element as the handle.
public final class AXWindowBridge: WindowFrameBridge {
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

    public func canTile(_ handle: AXUIElement) throws -> Bool {
        try checkPermission()
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(handle, attribute as CFString, &settable)
            if result != .success || !settable.boolValue { return false }
        }
        // Maximized (zoom-button, non-fullscreen) windows report settable
        // position/size yet ignore resizes, poisoning the whole batch.
        // Skip them read-only: never write, never auto-unzoom. A missing or
        // unreadable flag means NOT zoomed so prior behavior is preserved.
        if isZoomedOrFullscreen(handle) { return false }
        return true
    }

    /// Read-only zoom/fullscreen probe via public AX reads only.
    private func isZoomedOrFullscreen(_ handle: AXUIElement) -> Bool {
        for name in ["AXZoomed", "AXFullScreen", "AXFullscreen"] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(handle, name as CFString, &value)
            guard result == .success else { continue }
            if AXGeometryValidation.isZoomedFlag(value) { return true }
        }
        return false
    }

    /// Growth applies position-first so the enlarged frame fits the display;
    /// shrink and moves keep the size-first order. Callers roll back the
    /// entire previous frame on failure.
    public func apply(_ handle: AXUIElement, frame target: CGRect) throws {
        try checkPermission()
        guard AXGeometryValidation.isValidFrame(origin: target.origin, size: target.size) else {
            throw AXWindowError.invalidGeometry(.sizeWrite)
        }
        let current = try frame(of: handle)
        let changes = AXGeometryValidation.changes(from: current, to: target)
        let order = AXGeometryValidation.applyOrder(from: current, to: target)
        let sizeCheck = (kAXSizeAttribute, AXWindowError.Stage.sizeSettable,
                         AXWindowError.sizeNotSettable, changes.size)
        let positionCheck = (kAXPositionAttribute, AXWindowError.Stage.positionSettable,
                             AXWindowError.positionNotSettable, changes.position)
        let ordered = order == .positionFirst ? [positionCheck, sizeCheck] : [sizeCheck, positionCheck]
        for (attribute, stage, notSettable, changed) in ordered where changed {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(handle, attribute as CFString, &settable)
            guard result == .success else { throw AXWindowError.accessibility(stage: stage, error: result) }
            guard settable.boolValue else { throw notSettable }
        }
        switch order {
        case .positionFirst:
            if changes.position { try writePosition(handle, point: target.origin) }
            if changes.size { try writeSize(handle, size: target.size) }
        case .sizeFirst:
            if changes.size { try writeSize(handle, size: target.size) }
            if changes.position { try writePosition(handle, point: target.origin) }
        }
        let actual: CGRect
        do { actual = try frame(of: handle) }
        catch { throw AXWindowError.frameVerificationFailed(error) }
        guard AXGeometryValidation.matches(requested: target, actual: actual) else {
            throw AXWindowError.frameMismatch(requested: target, actual: actual)
        }
    }

    private func writeSize(_ handle: AXUIElement, size: CGSize) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { throw AXWindowError.invalidGeometry(.sizeWrite) }
        let result = AXUIElementSetAttributeValue(handle, kAXSizeAttribute as CFString, value)
        guard result == .success else { throw AXWindowError.accessibility(stage: .sizeWrite, error: result) }
    }

    private func writePosition(_ handle: AXUIElement, point: CGPoint) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw AXWindowError.invalidGeometry(.positionWrite)
        }
        let result = AXUIElementSetAttributeValue(handle, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw AXWindowError.accessibility(stage: .positionWrite, error: result) }
    }
}
