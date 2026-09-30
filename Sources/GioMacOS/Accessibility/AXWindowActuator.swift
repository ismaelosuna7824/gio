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
/// shrinking. Visible writes verify the changed attributes with ±1pt
/// readback; parked writes skip it (their clamped landing is accepted on
/// the next pass anyway).
public final class AXWindowActuator: WindowActuator {
    private struct Handle {
        let element: AXUIElement
        let appElement: AXUIElement
        let pid: pid_t
    }

    /// Reflow lanes read handles and the flip from several threads while the
    /// session queue may still register/forget (an abandoned lane can outlive
    /// its reflow), so all mutable state sits behind one lock.
    private let stateLock = NSLock()
    private var storedHandles: [UInt64: Handle] = [:]
    /// PA-04: element hash -> candidate ids; `CFEqual` verifies inside the bucket.
    private var handleIndex = HandleIndex<AXUIElement>(
        hash: { Int(truncatingIfNeeded: CFHash($0)) }, equal: { CFEqual($0, $1) }
    )
    private var storedFlip: AXVerticalFlip
    private var callCounts: [pid_t: Int] = [:]
    /// PA-03: call counting takes `stateLock` per AX call, so it only runs
    /// while the log level is debug. Set at startup and on config reload
    /// (session queue); lanes only read it, and a stale read merely counts
    /// or skips one call, so it is deliberately not locked.
    public nonisolated(unsafe) var countsCalls = false
    public var tracksCalls: Bool { countsCalls }

    /// Per-element AX messaging timeout. The system default is ~6s, which
    /// lets one hung app stall a whole reflow; a healthy app answers window
    /// attribute calls in a few ms. Set per element (the API does not share
    /// it between equal elements), so `register` applies it to both handles.
    public static let messagingTimeoutSeconds: Float = 0.25

    private var flip: AXVerticalFlip {
        stateLock.withLock { storedFlip }
    }

    /// - Parameter displayHeight: FULL display height for the AX flip
    ///   (RW-09: main display). Frames cross this boundary in Cocoa coords.
    public init(displayHeight: CGFloat) {
        self.storedFlip = AXVerticalFlip(displayHeight: displayHeight)
    }

    /// Refresh the flip height (display topology changed). Handles stay
    /// registered — only the coordinate frame updates.
    public func updateDisplayHeight(_ height: CGFloat) {
        stateLock.withLock { storedFlip = AXVerticalFlip(displayHeight: height) }
    }

    /// Raw element for live probes (tileability checks at reflow time).
    /// Pid-guarded like every other access.
    public func element(for id: WindowID) -> AXUIElement? {
        handle(for: id)?.element
    }

    /// Stable identity across re-enumerations: AX exposes no window number,
    /// so a retained handle matched with `CFEqual` is the identity. Nil
    /// means genuinely new (register it); never invent an ID per scan.
    public func id(matching element: AXUIElement, pid: pid_t) -> WindowID? {
        stateLock.withLock {
            handleIndex.find(element, pid: pid).map { WindowID(pid: pid, elementID: $0) }
        }
    }

    public func register(
        elementID: UInt64,
        pid: pid_t,
        element: AXUIElement,
        appElement: AXUIElement
    ) {
        // AX calls on Gio's own elements run AppKit in-process on the calling
        // (lane) thread and crash; Gio's windows are never actuated.
        guard isManageableProcess(
            pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier, onlyPID: nil
        ) else {
            return
        }
        _ = AXUIElementSetMessagingTimeout(element, Self.messagingTimeoutSeconds)
        _ = AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeoutSeconds)
        stateLock.withLock {
            storedHandles[elementID] = Handle(element: element, appElement: appElement, pid: pid)
            handleIndex.insert(elementID: elementID, pid: pid, element: element)
        }
    }

    public func forget(elementID: UInt64) {
        stateLock.withLock {
            storedHandles.removeValue(forKey: elementID)
            handleIndex.remove(elementID: elementID)
        }
    }

    public func axCallCount(forPid pid: pid_t) -> Int {
        stateLock.withLock { callCounts[pid, default: 0] }
    }

    private func countCalls(_ n: Int, pid: pid_t) {
        guard countsCalls else {
            return
        }
        stateLock.withLock { callCounts[pid, default: 0] += n }
    }

    private func handle(for id: WindowID) -> Handle? {
        stateLock.withLock {
            guard let handle = storedHandles[id.elementID], handle.pid == id.pid else {
                return nil
            }
            return handle
        }
    }

    public func frame(of id: WindowID) throws -> CGRect? {
        try actuatorPermission()
        guard let handle = handle(for: id) else {
            return nil
        }
        countCalls(2, pid: id.pid)
        return try readFrame(handle.element).map { flip.toCocoa($0) }
    }

    public func setFrame(_ frame: CGRect, for id: WindowID) throws {
        // Cold path (restore, one-off callers): the caller has no frame, so
        // read it once, then share the lean write.
        guard let current = try self.frame(of: id) else {
            throw SystemWindowActionError.frameMismatch(requested: frame, actual: .zero)
        }
        try setFrame(frame, from: current, for: id, verify: true)
    }

    /// Hot path (MO-02): no pre-read, no settable probes (tileability is
    /// cached per window by the host), only changed attributes are written,
    /// and only those are read back — nothing at all when `verify` is false.
    public func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
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
        let io = AXElementFrameIO(element: handle.element) { [self] in countCalls($0, pid: id.pid) }
        do {
            try writeFrame(current: flip.toAX(current), target: target, verify: verify, io: io)
        } catch FrameWriteError.mismatch(let actual) {
            throw SystemWindowActionError.frameMismatch(
                requested: frame, actual: actual == .zero ? .zero : flip.toCocoa(actual)
            )
        }
    }

    public func zoomAvailability(of id: WindowID) -> ZoomAvailability {
        guard (try? actuatorPermission()) != nil, let handle = handle(for: id) else {
            return .unavailable("noWindow")
        }
        countCalls(3, pid: id.pid)
        switch axZoomControl(of: handle.element) {
        case .usable: return .available
        case .unusable(let reason): return .unavailable(reason)
        }
    }

    /// Trigger the window's own zoom. Writes no frame: the app animates the
    /// window in-process, which is the point.
    public func pressZoom(id: WindowID) -> ZoomPressResult {
        guard (try? actuatorPermission()) != nil, let handle = handle(for: id) else {
            return .unavailable("noWindow")
        }
        countCalls(4, pid: id.pid)
        switch axZoomControl(of: handle.element) {
        case .unusable(let reason):
            return .unavailable(reason)
        case .usable(let button, let action):
            // The action returns only after the app started (often ran) its
            // zoom animation: give the button a longer timeout than the short
            // per-window one, and classify a timeout-class error as pending.
            _ = AXUIElementSetMessagingTimeout(button, NativeZoomLimits.zoomMessagingTimeout)
            let status = AXUIElementPerformAction(button, action as CFString)
            let result = zoomPressResult(forActionStatus: status.rawValue)
            if result != .pressed {
                GioLog.record(.debug, "native zoom action \(action) id=\(id.pid):\(id.elementID) axerror=\(status.rawValue)")
            }
            return result
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

/// `FrameAttributeIO` over a real window element; every call is counted.
struct AXElementFrameIO: FrameAttributeIO {
    let element: AXUIElement
    let count: (Int) -> Void

    func readPosition() throws -> CGPoint? {
        count(1)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw)
        if status == .invalidUIElement {
            return nil
        }
        var point = CGPoint.zero
        guard status == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite
        else {
            throw SystemWindowActionError.readbackFailed(attribute: "position", status: status)
        }
        return point
    }

    func readSize() throws -> CGSize? {
        count(1)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw)
        if status == .invalidUIElement {
            return nil
        }
        var size = CGSize.zero
        guard status == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cgSize, &size),
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else {
            throw SystemWindowActionError.readbackFailed(attribute: "size", status: status)
        }
        return size
    }

    func writePosition(_ point: CGPoint) throws {
        count(1)
        try writeAXPosition(point, to: element)
    }

    func writeSize(_ size: CGSize) throws {
        count(1)
        try writeAXSize(size, to: element)
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
