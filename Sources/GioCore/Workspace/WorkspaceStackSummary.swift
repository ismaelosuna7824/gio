import Foundation

/// One workspace of a display's stack as status, the menu bar and the
/// Overview show it: 1-based index, window and column counts, and whether it
/// is the display's active (shown) workspace. NW-02: named workspaces also
/// carry their `[[workspace]]` name, icon and color (nil when dynamic).
public struct WorkspaceEntry: Equatable, Sendable {
    public let index: Int
    public let windows: Int
    public let columns: Int
    public let isActive: Bool
    public let name: String?
    public let icon: String?
    public let color: String?
    /// DW-04: the workspace's layout (status, `gio list-workspaces`).
    public let layout: WorkspaceLayoutKind

    public init(
        index: Int, windows: Int, columns: Int, isActive: Bool,
        name: String? = nil, icon: String? = nil, color: String? = nil, layout: WorkspaceLayoutKind = .scrolling
    ) {
        self.index = index
        self.windows = windows
        self.columns = columns
        self.isActive = isActive
        self.name = name
        self.icon = icon
        self.color = color
        self.layout = layout
    }

    /// `3` for empty, `2 windows`-free compact form used in lists: `1 (3)`.
    public var label: String {
        "\(index) (\(windows == 0 ? "empty" : String(windows)))"
    }
}

/// A display's whole stack, top to bottom.
public struct DisplayStackSummary: Equatable, Sendable {
    public let display: DisplayID
    /// True for the display the hotkeys and `gio workspace N` act on.
    public let isFocused: Bool
    public let workspaces: [WorkspaceEntry]

    public init(display: DisplayID, isFocused: Bool, workspaces: [WorkspaceEntry]) {
        self.display = display
        self.isFocused = isFocused
        self.workspaces = workspaces
    }

    public var activeIndex: Int {
        workspaces.first { $0.isActive }?.index ?? 1
    }
}

extension WorkspaceManager {
    /// Every display's stack, in display order (`displayIDs`).
    public func stackSummaries() -> [DisplayStackSummary] {
        displayIDs.map { display in
            let active = activeID(on: display)
            let entries = stack(on: display).enumerated().map { offset, workspace in
                let definition = workspace.name.flatMap { name in
                    namedDefinitions.first { $0.name == name }
                }
                return WorkspaceEntry(
                    index: offset + 1,
                    windows: workspace.columns.map(\.windows.count).reduce(0, +),
                    columns: workspace.columns.count,
                    isActive: workspace.id == active,
                    name: workspace.name,
                    icon: definition?.icon,
                    color: definition?.color,
                    layout: workspace.layout
                )
            }
            return DisplayStackSummary(
                display: display, isFocused: display == focusedDisplay, workspaces: entries
            )
        }
    }
}
