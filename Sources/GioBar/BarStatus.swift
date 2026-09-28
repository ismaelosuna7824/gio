import Foundation

/// Pure menu-bar state: parsed from the IPC `status` JSON the daemon (and
/// today, any live session) serves. The AppKit shell renders this and
/// nothing else.
public struct BarSessionState: Equatable, Sendable {
    public var workspace: Int
    public var windows: Int
    public var columns: Int
    public var focused: String?

    public init(workspace: Int, windows: Int, columns: Int, focused: String?) {
        self.workspace = workspace
        self.windows = windows
        self.columns = columns
        self.focused = focused
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
    return BarSessionState(
        workspace: workspace, windows: windows, columns: columns, focused: focused
    )
}

/// `2 · 5` (workspace · windows), or `Gio` when no session answers.
public func barTitle(_ state: BarSessionState?) -> String {
    guard let state else {
        return "Gio"
    }
    return "\(state.workspace) · \(state.windows)"
}
