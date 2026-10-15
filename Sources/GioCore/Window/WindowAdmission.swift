import Foundation

/// Why a window is managed as floating instead of tiled.
public enum FloatReason: String, Equatable, Sendable {
    case dialog
    case floatingSubrole
    case notResizable
    /// Floated by a config window rule.
    case rule
    /// Floated by the user (toggle-floating).
    case manual
    /// FI-10: the app kept restoring its own frame after Gio wrote it
    /// (`SnapBackBook`): Gio stopped writing it until the user tiles it
    /// again (toggle-floating) or it is registered anew.
    case appControlled

    /// Floated by discovery for what the window is (a dialog, a floating
    /// subrole, a fixed size), not by a rule, the user or a snap-back.
    public var isAdmission: Bool {
        switch self {
        case .dialog, .floatingSubrole, .notResizable:
            true
        case .rule, .manual, .appControlled:
            false
        }
    }
}

/// Why a window is not managed at all.
public enum IgnoreReason: String, Equatable, Sendable {
    case notAWindow
    case sheetOrPopover
    case invalidFrame
}

/// Why a legitimate window cannot take part in the layout right now.
/// It stays a candidate: callers keep it and re-decide when the state ends.
public enum SuspendReason: String, Equatable, Sendable {
    case fullscreen
    case minimized
}

/// Observed facts about one window, as plain values (no AX types) so the
/// admission decision stays pure and testable.
public struct WindowAdmissionFacts: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var isPositionSettable: Bool
    public var isSizeSettable: Bool
    public var isFullscreen: Bool
    public var isMinimized: Bool
    public var hasValidFrame: Bool

    public init(
        role: String?,
        subrole: String?,
        isPositionSettable: Bool,
        isSizeSettable: Bool,
        isFullscreen: Bool = false,
        isMinimized: Bool = false,
        hasValidFrame: Bool = true
    ) {
        self.role = role
        self.subrole = subrole
        self.isPositionSettable = isPositionSettable
        self.isSizeSettable = isSizeSettable
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.hasValidFrame = hasValidFrame
    }
}

/// Outcome of admission: every window lands in exactly one bucket, and
/// every non-tile bucket carries its reason so nothing is dropped silently.
public enum WindowAdmission: Equatable, Sendable {
    case tile
    case float(FloatReason)
    case ignore(IgnoreReason)
    case suspend(SuspendReason)

    /// Short stable label for logs and status output.
    public var label: String {
        switch self {
        case .tile: return "tile"
        case .float(let reason): return "float(\(reason.rawValue))"
        case .ignore(let reason): return "ignore(\(reason.rawValue))"
        case .suspend(let reason): return "suspend(\(reason.rawValue))"
        }
    }
}

/// AX role/subrole strings, spelled out so GioCore needs no AX import.
private enum AXNames {
    static let window = "AXWindow"
    static let standard = "AXStandardWindow"
    static let dialog = "AXDialog"
    static let systemDialog = "AXSystemDialog"
    static let floating = "AXFloatingWindow"
    static let systemFloating = "AXSystemFloatingWindow"
    static let sheet = "AXSheet"
    static let popover = "AXPopover"
}

/// Decides how Gio treats a window. Order matters: identity (role/subrole)
/// first, then geometry, then transient state, then resizability.
///
/// An empty or unknown subrole is tiled when position and size are settable:
/// Electron, Java and Qt windows do not report AXStandardWindow but behave
/// like normal windows. Settability is the real capability check.
public func classifyWindowAdmission(_ facts: WindowAdmissionFacts) -> WindowAdmission {
    guard facts.role == AXNames.window else {
        return .ignore(.notAWindow)
    }
    let subrole = facts.subrole ?? ""
    switch subrole {
    case AXNames.sheet, AXNames.popover:
        return .ignore(.sheetOrPopover)
    case AXNames.dialog, AXNames.systemDialog:
        return .float(.dialog)
    case AXNames.floating, AXNames.systemFloating:
        return .float(.floatingSubrole)
    default:
        break
    }
    guard facts.hasValidFrame else {
        return .ignore(.invalidFrame)
    }
    if facts.isFullscreen {
        return .suspend(.fullscreen)
    }
    if facts.isMinimized {
        return .suspend(.minimized)
    }
    return facts.isPositionSettable && facts.isSizeSettable ? .tile : .float(.notResizable)
}

/// MM-12: admission is decided once, when the window is registered, from
/// what the app reports then. Live, Music's main window reported a dialog
/// at one startup and floated for the whole session, over and under the
/// tiles at its own frame. An admission float whose window now classifies
/// as a tile (`admission`, read again when it is activated) rejoins the
/// grid; floats a rule, the user or a snap-back chose never do.
public func promotesAdmissionFloat(_ window: ManagedWindow, to admission: WindowAdmission) -> Bool {
    window.mode == .floating && window.floatReason?.isAdmission == true && admission == .tile
}
