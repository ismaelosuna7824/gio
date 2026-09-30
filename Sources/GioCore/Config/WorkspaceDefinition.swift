import Foundation

/// NW-01: which display a named workspace lives on.
public enum WorkspaceDisplayAssignment: Equatable, Sendable {
    /// The main display (the first one the host registers).
    case main
    /// 1-based position in the host's display order; a display that is not
    /// connected falls back to the main display.
    case index(Int)
}

/// NW-01: one `[[workspace]]` entry. Named workspaces always exist (never
/// pruned when empty) and come first in their display's stack, in file order.
public struct WorkspaceDefinition: Equatable, Sendable {
    public var name: String
    /// SF Symbol name, shown by the UI; Core only stores it.
    public var icon: String?
    /// Hex color as written (validated by `ThemeColor(hex:)`).
    public var color: String?
    /// Nil means the main display.
    public var display: WorkspaceDisplayAssignment?

    public init(
        name: String, icon: String? = nil, color: String? = nil,
        display: WorkspaceDisplayAssignment? = nil
    ) {
        self.name = name
        self.icon = icon
        self.color = color
        self.display = display
    }
}
