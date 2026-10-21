import Foundation
import GioCore

/// Pure menu-bar state: built straight from the session
/// (`barSessionState(session:)`) or parsed from the IPC `status` JSON. The
/// AppKit shell renders this and nothing else.
public struct BarSessionState: Equatable, Sendable {
    public var workspace: Int
    public var windows: Int
    public var columns: Int
    /// Only presence matters to the menu (Move Window to Display), so focus
    /// moving between windows is not a bar change (PA-15a).
    public var hasFocusedWindow: Bool
    /// One dynamic workspace stack per display (NF-02); empty for older sessions.
    public var stacks: [BarStack]

    public init(
        workspace: Int, windows: Int, columns: Int, hasFocusedWindow: Bool = false, stacks: [BarStack] = []
    ) {
        self.workspace = workspace
        self.windows = windows
        self.columns = columns
        self.hasFocusedWindow = hasFocusedWindow
        self.stacks = stacks
    }
}

/// A display's workspace stack as the menu bar lists it.
public struct BarStack: Equatable, Sendable {
    public var display: UInt32
    /// The display the workspace hotkeys and `gio workspace N` act on.
    public var focused: Bool
    public var workspaces: [WorkspaceEntry]

    public init(display: UInt32, focused: Bool, workspaces: [WorkspaceEntry]) {
        self.display = display
        self.focused = focused
        self.workspaces = workspaces
    }
}

public func parseBarStatus(_ json: String) -> BarSessionState? {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let workspace = dict["workspace"] as? Int,
          let columns = dict["columns"] as? Int
    else {
        return nil
    }
    let windows = dict["windows"] as? Int ?? 0
    let hasFocusedWindow = dict["focusedWindow"] is String
    let stacks: [BarStack] = (dict["stacks"] as? [[String: Any]] ?? []).compactMap { raw in
        guard let display = raw["display"] as? Int,
              let entries = raw["workspaces"] as? [[String: Any]]
        else {
            return nil
        }
        let workspaces = entries.compactMap { entry -> WorkspaceEntry? in
            guard let index = entry["index"] as? Int else {
                return nil
            }
            return WorkspaceEntry(
                index: index, windows: entry["windows"] as? Int ?? 0,
                columns: entry["columns"] as? Int ?? 0, isActive: entry["active"] as? Bool ?? false,
                name: entry["name"] as? String, icon: entry["icon"] as? String, color: entry["color"] as? String
            )
        }
        return BarStack(
            display: UInt32(truncatingIfNeeded: display), focused: raw["focused"] as? Bool ?? false,
            workspaces: workspaces
        )
    }
    return BarSessionState(
        workspace: workspace, windows: windows, columns: columns, hasFocusedWindow: hasFocusedWindow, stacks: stacks
    )
}

/// PA-15a: the bar state read straight from the session, without the
/// `status` JSON round trip (which also serializes every window's title).
/// Same fields `parseBarStatus(queryStatus(session:))` yields; workspace
/// layouts are left out as there, since the bar does not show them.
public func barSessionState(session: CommandSession) -> BarSessionState {
    let workspace = session.manager.currentWorkspace()
    let stacks = session.manager.stackSummaries().map { summary in
        BarStack(
            display: summary.display.rawValue, focused: summary.isFocused,
            workspaces: summary.workspaces.map { entry in
                WorkspaceEntry(
                    index: entry.index, windows: entry.windows, columns: entry.columns, isActive: entry.isActive,
                    name: entry.name, icon: entry.icon, color: entry.color
                )
            }
        )
    }
    return BarSessionState(
        workspace: session.manager.current,
        windows: workspace.columns.map(\.windows.count).reduce(0, +),
        columns: workspace.columns.count,
        hasFocusedWindow: workspace.focusedWindow != nil,
        stacks: stacks
    )
}

/// `2 · 5` (workspace · windows), or `Gio` when no session answers.
public func barTitle(_ state: BarSessionState?) -> String {
    guard let state else {
        return "Gio"
    }
    return "\(state.workspace) · \(state.windows)"
}
