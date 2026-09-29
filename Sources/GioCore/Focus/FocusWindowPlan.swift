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
    /// 1-based index in the owning display's stack (stable id: `workspace.id`).
    public var index: Int
    public var workspace: Workspace
    public var switchesWorkspace: Bool
}

/// Nil when no workspace holds `id`.
public func planFocusWindow(_ id: WindowID, in manager: WorkspaceManager) -> WindowFocusPlan? {
    for workspace in manager.allWorkspaces {
        if let adopted = adoptingFocus(id, in: workspace), let place = manager.location(of: workspace.id) {
            return WindowFocusPlan(
                index: place.index, workspace: adopted,
                switchesWorkspace: workspace.id != manager.currentID
            )
        }
    }
    return nil
}
