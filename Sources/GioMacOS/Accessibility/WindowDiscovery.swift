import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore

public enum AXPermissionError: Error {
    case notTrusted
}

/// One enumerated window plus the retained AX handles needed to act on it.
/// Handles are valid for this process lifetime; a relaunch re-enumerates.
public struct DiscoveredSystemWindow {
    public let window: SystemWindow
    public let element: AXUIElement
    public let appElement: AXUIElement
    /// Set when admission floated the window (`.float(reason)`).
    public var floatReason: FloatReason? = nil
}

/// A window discovery saw but did not hand out as a tile candidate.
/// Never silent: each carries the admission decision that excluded it.
/// App name only (never the title) so it is safe to log.
public struct ExcludedSystemWindow: Equatable, Sendable {
    public let pid: pid_t
    public let appName: String
    public let admission: WindowAdmission
}

public struct SystemWindowDiscoveryResult {
    /// Tile candidates: windows admitted as `.tile`, plus fullscreen or
    /// minimized ones (`.suspend`) that callers filter by state.
    public let windows: [DiscoveredSystemWindow]
    /// Windows admitted as `.float(reason)` (dialogs, floating panels,
    /// fixed-size windows), with live handles. Registration is a later step.
    public let floating: [DiscoveredSystemWindow]
    /// Windows dropped as `.ignore(reason)` (not a window, sheet, bad frame).
    public let ignored: [ExcludedSystemWindow]
    /// Windows skipped because a required AX attribute was unreadable.
    /// Skips are evidence, never silent: callers must report the count.
    public let skipped: Int
}

public func requireAXPermission() throws {
    guard AXIsProcessTrusted() else {
        throw AXPermissionError.notTrusted
    }
}

/// - Parameter onlyPID: restrict the scan to one process (incremental
///   registration of a launched app); nil scans every regular app.
public func discoverSystemWindows(onlyPID: pid_t? = nil) throws -> SystemWindowDiscoveryResult {
    try requireAXPermission()
    var found: [DiscoveredSystemWindow] = []
    var floating: [DiscoveredSystemWindow] = []
    var ignored: [ExcludedSystemWindow] = []
    var skipped = 0
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && (onlyPID == nil || $0.processIdentifier == onlyPID)
    }
    for app in apps {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
            == .success,
            let elements = rawWindows as? [AXUIElement]
        else {
            continue
        }
        let focusedElement = axFocusedWindow(of: appElement)
        for element in elements {
            let appName = app.localizedName ?? "unknown"
            switch classifyElement(
                element, pid: app.processIdentifier, appName: appName,
                appElement: appElement, focused: focusedElement,
                index: found.count + floating.count
            ) {
            case .tile(let discovered):
                found.append(discovered)
            case .float(let discovered):
                floating.append(discovered)
            case .ignored(let excluded):
                ignored.append(excluded)
            case .skipped:
                skipped += 1
            }
        }
    }
    for entry in ignored {
        GioLog.record(
            .info, "discovery exclude pid=\(entry.pid) app=\(entry.appName) \(entry.admission.label)"
        )
    }
    if skipped > 0 {
        GioLog.record(.debug, "discovery skipped=\(skipped) windows with unreadable attributes")
    }
    return SystemWindowDiscoveryResult(
        windows: found, floating: floating, ignored: ignored, skipped: skipped
    )
}

private enum ElementClassification {
    case tile(DiscoveredSystemWindow)
    case float(DiscoveredSystemWindow)
    case ignored(ExcludedSystemWindow)
    case skipped
}

private func axFocusedWindow(of appElement: AXUIElement) -> AXUIElement? {
    var rawFocused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &rawFocused
    ) == .success,
        let candidate = rawFocused,
        CFGetTypeID(candidate) == AXUIElementGetTypeID()
    else {
        return nil
    }
    return (candidate as! AXUIElement)
}

/// Admission decision plus handles for one element. Shared by the full scan
/// and the single-window path used when a window appears later.
private func classifyElement(
    _ element: AXUIElement,
    pid: pid_t,
    appName: String,
    appElement: AXUIElement,
    focused focusedElement: AXUIElement?,
    index: Int
) -> ElementClassification {
    let frame = axFrame(of: element)
    let minimized = axBool(of: element, attribute: kAXMinimizedAttribute as String) ?? false
    let fullscreen = axBool(of: element, attribute: "AXFullScreen")
        ?? axBool(of: element, attribute: "AXFullscreen")
    let admission = classifyWindowAdmission(WindowAdmissionFacts(
        role: axString(of: element, attribute: kAXRoleAttribute as String),
        subrole: axString(of: element, attribute: kAXSubroleAttribute as String),
        isPositionSettable: axIsSettable(element, attribute: kAXPositionAttribute as String),
        isSizeSettable: axIsSettable(element, attribute: kAXSizeAttribute as String),
        isFullscreen: fullscreen ?? false,
        isMinimized: minimized,
        hasValidFrame: frame != nil
    ))
    if case .ignore = admission {
        return .ignored(ExcludedSystemWindow(pid: pid, appName: appName, admission: admission))
    }
    // Float/suspend/tile all have a valid frame except a dialog or floating
    // panel whose geometry is unreadable: count it as skipped.
    guard let frame else {
        return .skipped
    }
    let window = SystemWindow(
        index: index,
        pid: pid,
        appName: appName,
        title: axTitle(of: element),
        frame: frame,
        isFocused: focusedElement.map { CFEqual($0, element) } ?? false,
        isMinimized: minimized,
        isFullscreen: fullscreen
    )
    var discovered = DiscoveredSystemWindow(
        window: window, element: element, appElement: appElement
    )
    if case .float(let reason) = admission {
        discovered.floatReason = reason
        GioLog.record(
            .info, "discovery exclude pid=\(pid) app=\(appName) \(admission.label)"
        )
        return .float(discovered)
    }
    return .tile(discovered)
}

/// Classify one window that appeared after the initial scan. Nil when the
/// classifier ignores it or its geometry is not readable yet (the caller
/// may retry). Tile and float outcomes are both returned; minimized and
/// fullscreen windows come back flagged on `window` for the caller to filter.
public func discoverSystemWindow(element: AXUIElement, pid: pid_t) -> DiscoveredSystemWindow? {
    guard AXIsProcessTrusted() else {
        return nil
    }
    let appElement = AXUIElementCreateApplication(pid)
    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
    switch classifyElement(
        element, pid: pid, appName: appName, appElement: appElement,
        focused: axFocusedWindow(of: appElement), index: 0
    ) {
    case .tile(let discovered), .float(let discovered):
        return discovered
    case .ignored, .skipped:
        return nil
    }
}

/// Pre-tile probe: settable position/size and not native fullscreen
/// (fullscreen lives on its own Space — writes there are meaningless).
/// Zoomed (maximized) windows are ATTEMPTED, not skipped: setting a frame
/// normally resizes them fine, and the reconciler verifies per window, so
/// a refusal is recorded individually instead of poisoning anything. The
/// old skip-zoomed rule dated from one clamp observation that looks more
/// like minimum-size clamping; real apps decide live now. Live-only.
public func axIsTileable(_ element: AXUIElement) -> Bool {
    for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard status == .success, settable.boolValue else {
            return false
        }
    }
    for name in ["AXFullScreen", "AXFullscreen"] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            continue
        }
        if let fullscreen = raw as? Bool, fullscreen {
            return false
        }
    }
    return true
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

func axString(of element: AXUIElement, attribute: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
        return nil
    }
    return raw as? String
}

func axIsSettable(_ element: AXUIElement, attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        && settable.boolValue
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

public func axTitle(of element: AXUIElement) -> String? {
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
