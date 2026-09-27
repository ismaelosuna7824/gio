import ApplicationServices
import AppKit
import GioCore

/// Retains AX elements and compares them with CFEqual, never treating CFHash as unique.
public final class WindowDiscovery {
    private var known: [(id: WindowID, element: AXUIElement, pid: pid_t)] = []
    private var nextID = 0
    public init() {}

    /// A termination notification proves this PID's windows are gone; absence from AX does not.
    public func forgetTerminatedProcess(_ pid: pid_t) -> [WindowID] {
        let ids = known.filter { $0.pid == pid }.map(\.id)
        known.removeAll { $0.pid == pid }
        return ids
    }

    /// A missing known ID is only a candidate for a retained-handle validity check.
    public func missingKnownIDs(from windows: [(WindowID, AXUIElement, CGRect)]) -> [WindowID] {
        let seen = Set(windows.map(\.0))
        return known.map(\.id).filter { !seen.contains($0) }
    }

    public func forgetInvalidWindow(_ id: WindowID) {
        known.removeAll { $0.id == id }
    }

    public func windows() -> [(WindowID, AXUIElement, CGRect)] {
        var result: [(WindowID, AXUIElement, CGRect)] = []
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
                let id: WindowID
                if let existing = known.first(where: { $0.pid == app.processIdentifier && CFEqual($0.element, window) }) {
                    id = existing.id
                } else {
                    nextID += 1
                    id = WindowID("session-\(nextID)")
                    known.append((id, window, app.processIdentifier))
                }
                result.append((id, window, CGRect(origin: point, size: dimensions)))
            }
        }
        return result
    }
}
