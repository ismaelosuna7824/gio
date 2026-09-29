import Foundation
import GioCore

/// Pure menu-bar state: parsed from the IPC `status` JSON the daemon (and
/// today, any live session) serves. The AppKit shell renders this and
/// nothing else.
public struct BarSessionState: Equatable, Sendable {
    public var workspace: Int
    public var windows: Int
    public var columns: Int
    public var focused: String?
    /// One dynamic workspace stack per display (NF-02); empty for older sessions.
    public var stacks: [BarStack]

    public init(
        workspace: Int, windows: Int, columns: Int, focused: String?, stacks: [BarStack] = []
    ) {
        self.workspace = workspace
        self.windows = windows
        self.columns = columns
        self.focused = focused
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
    let focused = dict["focusedWindow"] as? String
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
                columns: entry["columns"] as? Int ?? 0, isActive: entry["active"] as? Bool ?? false
            )
        }
        return BarStack(
            display: UInt32(truncatingIfNeeded: display), focused: raw["focused"] as? Bool ?? false,
            workspaces: workspaces
        )
    }
    return BarSessionState(
        workspace: workspace, windows: windows, columns: columns, focused: focused, stacks: stacks
    )
}

/// `2 · 5` (workspace · windows), or `Gio` when no session answers.
public func barTitle(_ state: BarSessionState?) -> String {
    guard let state else {
        return "Gio"
    }
    return "\(state.workspace) · \(state.windows)"
}
