import ApplicationServices
import AppKit
import GioCore

/// Retains AX elements and compares them with CFEqual, never treating CFHash as unique.
public final class WindowDiscovery {
    private var known: [(id: LegacyWindowID, element: AXUIElement, pid: pid_t)] = []
    private var nextID = 0
    public init() {}

    /// A termination notification proves this PID's windows are gone; absence from AX does not.
    public func forgetTerminatedProcess(_ pid: pid_t) -> [LegacyWindowID] {
        let ids = known.filter { $0.pid == pid }.map(\.id)
        known.removeAll { $0.pid == pid }
        return ids
    }

    /// A missing known ID is only a candidate for a retained-handle validity check.
    public func missingKnownIDs(from windows: [(LegacyWindowID, AXUIElement, CGRect)]) -> [LegacyWindowID] {
        let seen = Set(windows.map(\.0))
        return known.map(\.id).filter { !seen.contains($0) }
    }

    public func forgetInvalidWindow(_ id: LegacyWindowID) {
        known.removeAll { $0.id == id }
    }

    /// Only an explicitly absent AX title is optional; malformed success is not absence.
    static func normalizedTitle(status: AXError, value: CFTypeRef?, pid: pid_t) throws -> String? {
        switch status {
        case .noValue, .attributeUnsupported: return nil
        case .success:
            guard let title = value as? String else { throw SpaceWindowSnapshotError.incompletePID(pid) }
            return title.isEmpty ? nil : title
        default: throw SpaceWindowSnapshotError.incompletePID(pid)
        }
    }

    /// Enumerate all standard AX windows for a relevant PID, including other Spaces.
    /// Any uncertain role or incomplete standard window invalidates the whole PID snapshot.
    public func snapshotWindows(pid: pid_t) throws -> [SpaceWindowSnapshot.Window] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            throw SpaceWindowSnapshotError.incompletePID(pid)
        }
        var result: [SpaceWindowSnapshot.Window] = []
        for element in elements {
            func attribute(_ name: String) throws -> CFTypeRef {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                      let value else { throw SpaceWindowSnapshotError.incompletePID(pid) }
                return value
            }
            guard let role = try attribute(kAXRoleAttribute as String) as? String else {
                throw SpaceWindowSnapshotError.incompletePID(pid)
            }
            if role != (kAXWindowRole as String) { continue }
            guard let subrole = try attribute(kAXSubroleAttribute as String) as? String else {
                throw SpaceWindowSnapshotError.incompletePID(pid)
            }
            if subrole != (kAXStandardWindowSubrole as String) { continue }
            var titleValue: CFTypeRef?
            let titleStatus = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
            let title = try Self.normalizedTitle(status: titleStatus, value: titleValue, pid: pid)
            let position = try attribute(kAXPositionAttribute as String)
            let size = try attribute(kAXSizeAttribute as String)
            guard CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID() else {
                throw SpaceWindowSnapshotError.incompletePID(pid)
            }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
                throw SpaceWindowSnapshotError.incompletePID(pid)
            }
            let frame = CGRect(origin: point, size: dimensions)
            guard dimensions.width > 0, dimensions.height > 0,
                  [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
                throw SpaceWindowSnapshotError.incompletePID(pid)
            }
            let id: LegacyWindowID
            if let existing = known.first(where: { $0.pid == pid && CFEqual($0.element, element) }) {
                id = existing.id
            } else {
                nextID += 1
                id = LegacyWindowID("session-\(nextID)")
                known.append((id, element, pid))
            }
            let bounds = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
                return bounds.contains(frame) ? bounds : nil
            }.first
            result.append(.init(id: id, element: element, pid: pid, title: title,
                                frame: frame, displayBounds: bounds))
        }
        return result
    }

    public func windows() -> [(LegacyWindowID, AXUIElement, CGRect)] {
        var result: [(LegacyWindowID, AXUIElement, CGRect)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var role: CFTypeRef?
                var subrole: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                      (role as? String) == (kAXWindowRole as String),
                      AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
                      (subrole as? String) == (kAXStandardWindowSubrole as String) else { continue }
                var position: CFTypeRef?
                var size: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                      let position, let size,
                      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                      AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                      dimensions.width > 0, dimensions.height > 0 else { continue }
                let id: LegacyWindowID
                if let existing = known.first(where: { $0.pid == app.processIdentifier && CFEqual($0.element, window) }) {
                    id = existing.id
                } else {
                    nextID += 1
                    id = LegacyWindowID("session-\(nextID)")
                    known.append((id, window, app.processIdentifier))
                }
                result.append((id, window, CGRect(origin: point, size: dimensions)))
            }
        }
        return result
    }
}
