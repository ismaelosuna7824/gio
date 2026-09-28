import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore

/// The concrete `WindowActuator` over public Accessibility APIs: the only
/// new-architecture path that writes physical window frames. Handles are
/// registered per `elementID` by the assembly layer (RW-09); the pid stored
/// alongside guards against pid reuse — a mismatched pid reads as vanished,
/// never as another window.
///
/// Write order relearns the hard-won rule: position-first when the target
/// grows in either dimension (a size-first write of a large frame from a
/// small tiled position overflows and macOS clamps it), size-first when
/// shrinking. Every write verifies with ±1pt readback.
public final class AXWindowActuator: WindowActuator {
    private struct Handle {
        let element: AXUIElement
        let appElement: AXUIElement
        let pid: pid_t
    }

    private var handles: [UInt64: Handle] = [:]
    private var flip: AXVerticalFlip

    /// - Parameter displayHeight: FULL display height for the AX flip
    ///   (RW-09: main display). Frames cross this boundary in Cocoa coords.
    public init(displayHeight: CGFloat) {
        self.flip = AXVerticalFlip(displayHeight: displayHeight)
    }

    /// Refresh the flip height (display topology changed). Handles stay
    /// registered — only the coordinate frame updates.
    public func updateDisplayHeight(_ height: CGFloat) {
        flip = AXVerticalFlip(displayHeight: height)
    }

    /// Raw element for live probes (tileability checks at reflow time).
    /// Pid-guarded like every other access.
    public func element(for id: WindowID) -> AXUIElement? {
        handle(for: id)?.element
    }

    public func register(
        elementID: UInt64,
        pid: pid_t,
        element: AXUIElement,
        appElement: AXUIElement
    ) {
        handles[elementID] = Handle(element: element, appElement: appElement, pid: pid)
    }

    public func forget(elementID: UInt64) {
        handles.removeValue(forKey: elementID)
    }

    private func handle(for id: WindowID) -> Handle? {
        guard let handle = handles[id.elementID], handle.pid == id.pid else {
            return nil
        }
        return handle
    }

    public func frame(of id: WindowID) throws -> CGRect? {
        try actuatorPermission()
        guard let handle = handle(for: id) else {
            return nil
        }
        return try readFrame(handle.element).map { flip.toCocoa($0) }
    }

    public func setFrame(_ frame: CGRect, for id: WindowID) throws {
        // Cocoa in, AX on the wire: convert first, then all logic below is
        // in AX space (order rule, verification). Returned frame is Cocoa.
        let target = flip.toAX(frame)
        try actuatorPermission()
        guard target.origin.x.isFinite, target.origin.y.isFinite,
              target.size.width.isFinite, target.size.height.isFinite,
              target.size.width > 0, target.size.height > 0
        else {
            throw SystemWindowActionError.writeFailed(attribute: "frame", status: .failure)
        }
        guard let handle = handle(for: id) else {
            throw SystemWindowActionError.unknownHandle(elementID: id.elementID)
        }
        let current = try readFrame(handle.element)
        guard let current else {
            // Vanished between diff and write: report honestly, write nothing.
            throw SystemWindowActionError.frameMismatch(requested: frame, actual: .zero)
        }
        if framesEqual(current, target) {
            return
        }
        try checkAXSettable(handle.element, attribute: kAXPositionAttribute as String)
        try checkAXSettable(handle.element, attribute: kAXSizeAttribute as String)
        let growing = target.size.width > current.size.width + 1
            || target.size.height > current.size.height + 1
        if growing {
            try writeAXPosition(target.origin, to: handle.element)
            try writeAXSize(target.size, to: handle.element)
        } else {
            try writeAXSize(target.size, to: handle.element)
            try writeAXPosition(target.origin, to: handle.element)
        }
        let actual = try readFrame(handle.element)
        guard let actual, framesEqual(actual, target) else {
            throw SystemWindowActionError.frameMismatch(
                requested: frame, actual: actual.map { flip.toCocoa($0) } ?? .zero
            )
        }
    }

    public func focus(id: WindowID) throws {
        try actuatorPermission()
        guard let handle = handle(for: id) else {
            throw SystemWindowActionError.unknownHandle(elementID: id.elementID)
        }
        try focusAXWindow(appElement: handle.appElement, element: handle.element, pid: handle.pid)
    }
}

func actuatorPermission() throws {
    do {
        try requireAXPermission()
    } catch {
        throw SystemWindowActionError.permissionDenied
    }
}

/// Nil only when macOS reports the element invalid; every other read failure
/// throws, so live-but-unreadable windows are never mislabeled as vanished.
func readFrame(_ element: AXUIElement) throws -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    let positionStatus = AXUIElementCopyAttributeValue(
        element, kAXPositionAttribute as CFString, &rawPosition
    )
    let sizeStatus = AXUIElementCopyAttributeValue(
        element, kAXSizeAttribute as CFString, &rawSize
    )
    if positionStatus == .invalidUIElement || sizeStatus == .invalidUIElement {
        return nil
    }
    guard positionStatus == .success else {
        throw SystemWindowActionError.readbackFailed(attribute: "position", status: positionStatus)
    }
    guard sizeStatus == .success else {
        throw SystemWindowActionError.readbackFailed(attribute: "size", status: sizeStatus)
    }
    guard let position = rawPosition, let size = rawSize,
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID()
    else {
        throw SystemWindowActionError.readbackFailed(attribute: "position/size", status: .failure)
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite,
          dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0
    else {
        throw SystemWindowActionError.readbackFailed(attribute: "position/size", status: .failure)
    }
    return CGRect(origin: point, size: dimensions)
}

func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= 1
        && abs(lhs.origin.y - rhs.origin.y) <= 1
        && abs(lhs.size.width - rhs.size.width) <= 1
        && abs(lhs.size.height - rhs.size.height) <= 1
}

func checkAXSettable(_ element: AXUIElement, attribute: String) throws {
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    guard status == .success, settable.boolValue else {
        if status != .success {
            throw SystemWindowActionError.writeFailed(attribute: attribute, status: status)
        }
        throw SystemWindowActionError.notSettable(attribute: attribute)
    }
}

func writeAXSize(_ size: CGSize, to element: AXUIElement) throws {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else {
        throw SystemWindowActionError.writeFailed(attribute: "size", status: .failure)
    }
    let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    guard status == .success else {
        throw SystemWindowActionError.writeFailed(attribute: "size", status: status)
    }
}

func writeAXPosition(_ point: CGPoint, to element: AXUIElement) throws {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else {
        throw SystemWindowActionError.writeFailed(attribute: "position", status: .failure)
    }
    let status = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    guard status == .success else {
        throw SystemWindowActionError.writeFailed(attribute: "position", status: status)
    }
}
