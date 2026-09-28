import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum AXPermissionError: Error {
    case notTrusted
}

/// One enumerated window plus the retained AX handles needed to act on it.
/// Handles are valid for this process lifetime; a relaunch re-enumerates.
public struct DiscoveredSystemWindow {
    public let window: SystemWindow
    public let element: AXUIElement
    public let appElement: AXUIElement
}

public struct SystemWindowDiscoveryResult {
    public let windows: [DiscoveredSystemWindow]
    /// Windows skipped because a required AX attribute was unreadable.
    /// Skips are evidence, never silent: callers must report the count.
    public let skipped: Int
}

public func requireAXPermission() throws {
    guard AXIsProcessTrusted() else {
        throw AXPermissionError.notTrusted
    }
}

public func discoverSystemWindows() throws -> SystemWindowDiscoveryResult {
    try requireAXPermission()
    var found: [DiscoveredSystemWindow] = []
    var skipped = 0
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    for app in apps {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
            == .success,
            let elements = rawWindows as? [AXUIElement]
        else {
            continue
        }
        var rawFocused: CFTypeRef?
        let focusedElement: AXUIElement? = {
            guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &rawFocused
            ) == .success,
                let candidate = rawFocused,
                CFGetTypeID(candidate) == AXUIElementGetTypeID()
            else {
                return nil
            }
            return (candidate as! AXUIElement)
        }()
        for element in elements {
            guard axIsStandardWindow(element) else {
                continue
            }
            guard let frame = axFrame(of: element) else {
                skipped += 1
                continue
            }
            let minimized = axBool(of: element, attribute: kAXMinimizedAttribute as String) ?? false
            let fullscreen = axBool(of: element, attribute: "AXFullScreen")
                ?? axBool(of: element, attribute: "AXFullscreen")
            let focused = focusedElement.map { CFEqual($0, element) } ?? false
            let window = SystemWindow(
                index: found.count,
                pid: app.processIdentifier,
                appName: app.localizedName ?? "unknown",
                title: axTitle(of: element),
                frame: frame,
                isFocused: focused,
                isMinimized: minimized,
                isFullscreen: fullscreen
            )
            found.append(DiscoveredSystemWindow(window: window, element: element, appElement: appElement))
        }
    }
    return SystemWindowDiscoveryResult(windows: found, skipped: skipped)
}

func axIsStandardWindow(_ element: AXUIElement) -> Bool {
    var rawRole: CFTypeRef?
    var rawSubrole: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
          (rawRole as? String) == (kAXWindowRole as String),
          AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &rawSubrole)
              == .success,
          (rawSubrole as? String) == (kAXStandardWindowSubrole as String)
    else {
        return false
    }
    return true
}

func axFrame(of element: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition)
        == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
        let position = rawPosition,
        let size = rawSize,
        CFGetTypeID(position) == AXValueGetTypeID(),
        CFGetTypeID(size) == AXValueGetTypeID()
    else {
        return nil
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite,
          dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0
    else {
        return nil
    }
    return CGRect(origin: point, size: dimensions)
}

func axTitle(of element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw)
    switch status {
    case .noValue, .attributeUnsupported:
        return nil
    case .success:
        guard let title = raw as? String, !title.isEmpty else {
            return nil
        }
        return title
    default:
        return nil
    }
}

func axBool(of element: AXUIElement, attribute: String) -> Bool? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
        return nil
    }
    return raw as? Bool
}
