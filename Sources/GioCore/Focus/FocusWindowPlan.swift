import Foundation

extension WindowID {
    /// Parses the `pid:elementID` text the status query and window facts use.
    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let pid = pid_t(parts[0]), pid >= 0,
              let element = UInt64(parts[1])
        else {
            return nil
        }
        self.init(pid: pid, elementID: element)
    }
}

/// Focusing one specific managed window: which workspace owns it, whether the
/// session has to switch there, and that workspace with the window adopted as
/// its focus. Pure; the host applies it and asks the reconciler to focus.
public struct WindowFocusPlan: Equatable, Sendable {
    public var index: Int
    public var workspace: Workspace
    public var switchesWorkspace: Bool
}

/// Nil when no workspace holds `id`.
public func planFocusWindow(_ id: WindowID, in manager: WorkspaceManager) -> WindowFocusPlan? {
    for index in WorkspaceManager.range {
        if let workspace = manager.workspace(index), let adopted = adoptingFocus(id, in: workspace) {
            return WindowFocusPlan(index: index, workspace: adopted, switchesWorkspace: index != manager.current)
        }
    }
    return nil
}
