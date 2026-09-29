import Foundation

/// One workspace of a display's stack as status, the menu bar and the
/// Overview show it: 1-based index, window and column counts, and whether it
/// is the display's active (shown) workspace.
public struct WorkspaceEntry: Equatable, Sendable {
    public let index: Int
    public let windows: Int
    public let columns: Int
    public let isActive: Bool

    public init(index: Int, windows: Int, columns: Int, isActive: Bool) {
        self.index = index
        self.windows = windows
        self.columns = columns
        self.isActive = isActive
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
    /// Every display's stack, in display registration order.
    public func stackSummaries() -> [DisplayStackSummary] {
        displayIDs.map { display in
            let active = activeID(on: display)
            let entries = stack(on: display).enumerated().map { offset, workspace in
                WorkspaceEntry(
                    index: offset + 1,
                    windows: workspace.columns.map(\.windows.count).reduce(0, +),
                    columns: workspace.columns.count,
                    isActive: workspace.id == active
                )
            }
            return DisplayStackSummary(
                display: display, isFocused: display == focusedDisplay, workspaces: entries
            )
        }
    }
}
