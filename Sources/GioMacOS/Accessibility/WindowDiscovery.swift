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

    public init(window: SystemWindow, element: AXUIElement, appElement: AXUIElement, floatReason: FloatReason? = nil) {
        self.window = window
        self.element = element
        self.appElement = appElement
        self.floatReason = floatReason
    }
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
    /// Pids whose window list was read successfully and whose every element
    /// was classified (none skipped). Only for these is absence from the scan
    /// evidence that a registered window is gone.
    public let completePIDs: Set<pid_t>

    public init(
        windows: [DiscoveredSystemWindow], floating: [DiscoveredSystemWindow] = [],
        ignored: [ExcludedSystemWindow] = [], skipped: Int = 0, completePIDs: Set<pid_t>
    ) {
        self.windows = windows
        self.floating = floating
        self.ignored = ignored
        self.skipped = skipped
        self.completePIDs = completePIDs
    }
}

/// Gio's own windows (main window, launcher) are never managed, whatever
/// the activation policy is at the moment.
public func isManageableProcess(pid: pid_t, ownPID: pid_t, onlyPID: pid_t?) -> Bool {
    pid != ownPID && (onlyPID == nil || pid == onlyPID)
}

public func requireAXPermission() throws {
    guard AXIsProcessTrusted() else {
        throw AXPermissionError.notTrusted
    }
}

/// - Parameter onlyPID: restrict the scan to one process (incremental
///   registration of a launched app); nil scans every regular app.
/// - Parameter isKnown: elements the caller already manages. PA-18a: their
///   settable probes (two messages each) are skipped, so a known window
///   comes back as a tile candidate whatever its resizability; only for a
///   caller that treats known tile and float candidates alike.
public func discoverSystemWindows(
    onlyPID: pid_t? = nil, isKnown: (AXUIElement, pid_t) -> Bool = { _, _ in false }
) throws -> SystemWindowDiscoveryResult {
    try requireAXPermission()
    var found: [DiscoveredSystemWindow] = []
    var floating: [DiscoveredSystemWindow] = []
    var ignored: [ExcludedSystemWindow] = []
    var skipped = 0
    var completePIDs = Set<pid_t>()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && isManageableProcess(
            pid: $0.processIdentifier, ownPID: ownPID, onlyPID: onlyPID
        )
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
        let skippedBefore = skipped
        defer {
            if skipped == skippedBefore {
                completePIDs.insert(app.processIdentifier)
            }
        }
        for element in elements {
            let appName = app.localizedName ?? "unknown"
            switch classifyElement(
                element, facts: readWindowFacts(element),
                probesSettable: !isKnown(element, app.processIdentifier),
                pid: app.processIdentifier, appName: appName, bundleID: app.bundleIdentifier,
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
        windows: found, floating: floating, ignored: ignored, skipped: skipped,
        completePIDs: completePIDs
    )
}

private enum ElementClassification {
    case tile(DiscoveredSystemWindow)
    case float(DiscoveredSystemWindow)
    case ignored(ExcludedSystemWindow)
    case skipped
}

/// The app's current key window, if any (light-path focus adoption).
public func focusedWindowElement(pid: pid_t) -> AXUIElement? {
    axFocusedWindow(of: AXUIElementCreateApplication(pid))
}

/// WC-11: the app's fresh `kAXWindowsAttribute` list, one AX call. Only the
/// front tab of a native tab group is in it (background tabs' handles keep
/// resolving). Nil when unreadable, and always for Gio's own pid.
public func axWindowElements(pid: pid_t) -> [AXUIElement]? {
    guard pid != ProcessInfo.processInfo.processIdentifier else {
        return nil
    }
    var rawWindows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &rawWindows
    ) == .success else {
        return nil
    }
    return rawWindows as? [AXUIElement]
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

/// PA-18a: what classification needs of one window. Unreadable attributes
/// are nil, as the single-attribute reads they replace reported them.
struct AXWindowFacts: Equatable {
    /// Nil unless position and size are both readable, finite and positive.
    var frame: CGRect?
    var minimized: Bool?
    /// `AXFullScreen`, else the `AXFullscreen` spelling some apps use.
    var fullscreen: Bool?
    var role: String?
    var subrole: String?
    /// Nil when unreadable or empty.
    var title: String?
    /// The role answered, whatever its value (PF-E: a readable "not a
    /// window" is final, an unreadable role is worth another try).
    var roleReadable: Bool
    /// macOS reports the element invalid (destroyed).
    var elementGone: Bool
}

/// The attributes of `AXWindowFacts`, in slot order.
let windowFactAttributes: [String] = [
    kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen", "AXFullscreen",
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
]

/// PA-18a: every fact in one Accessibility message
/// (`AXUIElementCopyMultipleAttributeValues`) instead of one per attribute.
func readWindowFacts(_ element: AXUIElement) -> AXWindowFacts {
    var raw: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
        element, windowFactAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
    )
    return decodeWindowFacts(status: status, values: raw as? [AnyObject])
}

/// One slot of a batched read: its value, or the error macOS put in its
/// place (an `AXValue` of type `.axError`).
private enum AXSlot {
    case value(AnyObject)
    case error(AXError)
}

/// Pure: decodes a batched read of `windowFactAttributes`. A failed call
/// fails every slot with its status.
func decodeWindowFacts(status: AXError, values: [AnyObject]?) -> AXWindowFacts {
    let slots: [AXSlot]
    if status == .success, let values, values.count == windowFactAttributes.count {
        slots = values.map(axSlot)
    } else {
        slots = Array(repeating: .error(status == .success ? .failure : status), count: windowFactAttributes.count)
    }
    func value(_ index: Int) -> AnyObject? {
        if case .value(let value) = slots[index] {
            return value
        }
        return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    let frame: CGRect?
    if let position = value(0), CFGetTypeID(position) == AXValueGetTypeID(),
       AXValueGetValue(position as! AXValue, .cgPoint, &point),
       let extent = value(1), CFGetTypeID(extent) == AXValueGetTypeID(),
       AXValueGetValue(extent as! AXValue, .cgSize, &size),
       point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
       size.width > 0, size.height > 0
    {
        frame = CGRect(origin: point, size: size)
    } else {
        frame = nil
    }
    let title = value(7) as? String
    var roleReadable = false
    var elementGone = false
    switch slots[5] {
    case .value:
        roleReadable = true
    case .error(let error):
        elementGone = error == .invalidUIElement
    }
    return AXWindowFacts(
        frame: frame,
        minimized: value(2) as? Bool,
        fullscreen: (value(3) as? Bool) ?? (value(4) as? Bool),
        role: value(5) as? String,
        subrole: value(6) as? String,
        title: title?.isEmpty == false ? title : nil,
        roleReadable: roleReadable,
        elementGone: elementGone
    )
}

private func axSlot(_ value: AnyObject) -> AXSlot {
    if CFGetTypeID(value) == CFNullGetTypeID() {
        return .error(.noValue)
    }
    guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else {
        return .value(value)
    }
    var error = AXError.failure
    _ = AXValueGetValue(value as! AXValue, .axError, &error)
    return .error(error)
}

/// Admission decision plus handles for one element. Shared by the full scan
/// and the single-window path used when a window appears later.
/// `probesSettable` false skips the settable probes (a known window).
private func classifyElement(
    _ element: AXUIElement,
    facts: AXWindowFacts,
    probesSettable: Bool = true,
    pid: pid_t,
    appName: String,
    bundleID: String?,
    appElement: AXUIElement,
    focused focusedElement: AXUIElement?,
    index: Int
) -> ElementClassification {
    let admission = windowAdmission(of: element, facts: facts, probesSettable: probesSettable)
    if case .ignore = admission {
        return .ignored(ExcludedSystemWindow(pid: pid, appName: appName, admission: admission))
    }
    // Float/suspend/tile all have a valid frame except a dialog or floating
    // panel whose geometry is unreadable: count it as skipped.
    guard let frame = facts.frame else {
        return .skipped
    }
    let window = SystemWindow(
        index: index,
        pid: pid,
        appName: appName,
        title: facts.title,
        frame: frame,
        isFocused: focusedElement.map { CFEqual($0, element) } ?? false,
        isMinimized: facts.minimized ?? false,
        isFullscreen: facts.fullscreen,
        bundleID: bundleID
    )
    var discovered = DiscoveredSystemWindow(
        window: window, element: element, appElement: appElement
    )
    if case .float(let reason) = admission {
        // MM-12: logged with its id once registered (`window float`).
        discovered.floatReason = reason
        return .float(discovered)
    }
    return .tile(discovered)
}

/// The settable probes run only when admission reaches them (PA-18a).
private func windowAdmission(
    of element: AXUIElement, facts: AXWindowFacts, probesSettable: Bool = true
) -> WindowAdmission {
    classifyWindowAdmission(WindowAdmissionFacts(
        role: facts.role,
        subrole: facts.subrole,
        isPositionSettable: { !probesSettable || axIsSettable(element, attribute: kAXPositionAttribute as String) },
        isSizeSettable: { !probesSettable || axIsSettable(element, attribute: kAXSizeAttribute as String) },
        isFullscreen: facts.fullscreen ?? false,
        isMinimized: facts.minimized ?? false,
        hasValidFrame: facts.frame != nil
    ))
}

/// MM-12: the admission a registered window would get now (a fresh read of
/// role, subrole, settability and state). Never for Gio's own pid.
public func currentWindowAdmission(of element: AXUIElement, pid: pid_t) -> WindowAdmission? {
    guard pid != ProcessInfo.processInfo.processIdentifier else {
        return nil
    }
    return windowAdmission(of: element, facts: readWindowFacts(element))
}

/// PF-02: one appeared element's classification, with why it failed: a
/// brand-new window whose frame is not readable yet is retried sooner.
public enum SingleWindowDiscovery {
    case found(DiscoveredSystemWindow)
    /// Its frame (position/size) is not readable yet.
    case frameUnreadable
    /// Ignored by admission, untrusted, or not a manageable process.
    case unclassified
    /// PF-E: the element was destroyed before it could be read.
    case gone
    /// PF-E: readable, and admission says it is not a window to manage.
    case rejected
}

/// PF-02: `discoverSystemWindow` with the failure reason.
public func discoverSystemWindowAttempt(element: AXUIElement, pid: pid_t) -> SingleWindowDiscovery {
    guard isManageableProcess(pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier, onlyPID: nil),
          AXIsProcessTrusted()
    else {
        return .unclassified
    }
    let appElement = AXUIElementCreateApplication(pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let appName = app?.localizedName ?? "unknown"
    let facts = readWindowFacts(element)
    let ignore: IgnoreReason?
    switch classifyElement(
        element, facts: facts, pid: pid, appName: appName, bundleID: app?.bundleIdentifier,
        appElement: appElement, focused: axFocusedWindow(of: appElement), index: 0
    ) {
    case .tile(let discovered), .float(let discovered):
        return .found(discovered)
    case .skipped:
        ignore = nil
    case .ignored(let excluded):
        if case .ignore(let reason) = excluded.admission {
            ignore = reason
        } else {
            ignore = nil
        }
    }
    // The same read tells a destroyed element (closed before it could be
    // read: never retry) from one that does not answer yet.
    switch registrationFailure(
        elementGone: facts.elementGone, roleReadable: facts.roleReadable,
        frameReadable: facts.frame != nil, ignore: ignore
    ) {
    case .gone: return .gone
    case .rejected: return .rejected
    case .frameUnreadable: return .frameUnreadable
    case .unclassified: return .unclassified
    }
}

/// Classify one window that appeared after the initial scan. Nil when the
/// classifier ignores it or its geometry is not readable yet (the caller
/// may retry). Tile and float outcomes are both returned; minimized and
/// fullscreen windows come back flagged on `window` for the caller to filter.
public func discoverSystemWindow(element: AXUIElement, pid: pid_t) -> DiscoveredSystemWindow? {
    guard isManageableProcess(pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier, onlyPID: nil),
          AXIsProcessTrusted()
    else {
        return nil
    }
    let appElement = AXUIElementCreateApplication(pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let appName = app?.localizedName ?? "unknown"
    switch classifyElement(
        element, facts: readWindowFacts(element), pid: pid, appName: appName,
        bundleID: app?.bundleIdentifier, appElement: appElement,
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
    axTileability(element) == .tileable
}

public func axTileability(_ element: AXUIElement) -> TileabilityProbe {
    for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard status == .success else {
            return .undetermined(status: Int(status.rawValue))
        }
        guard settable.boolValue else {
            return .notTileable
        }
    }
    for name in ["AXFullScreen", "AXFullscreen"] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            continue
        }
        if let fullscreen = raw as? Bool, fullscreen {
            return .notTileable
        }
    }
    return .tileable
}

/// Whether the window's size attribute is settable (the latency probe skips
/// windows that cannot be resized). Live-only.
public func axIsSizeSettable(_ element: AXUIElement) -> Bool {
    axIsSettable(element, attribute: kAXSizeAttribute as String)
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

/// Nil on any failure (discovery retries); one message (PF-AE, `readFrame`).
func axFrame(of element: AXUIElement) -> CGRect? {
    (try? readFrame(element)) ?? nil
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
