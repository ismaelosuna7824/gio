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
    /// The session's current workspace changes (another workspace, possibly
    /// one already shown on another display).
    public var switchesWorkspace: Bool
    /// MM-01: the workspace is not on screen yet, so a display really
    /// switches; false when it is shown on another display and only the
    /// focused display changes.
    public var revealsHiddenWorkspace: Bool

    /// The motion cause of applying the plan: a slide only when a display
    /// switches; moving the focus to another display's shown workspace
    /// moves nothing by itself.
    public var revealCause: MotionCause {
        revealsHiddenWorkspace ? .workspaceSwitch : .passive
    }
}

/// Nil when no workspace holds `id`.
public func planFocusWindow(_ id: WindowID, in manager: WorkspaceManager) -> WindowFocusPlan? {
    for workspace in manager.allWorkspaces {
        if let adopted = adoptingFocus(id, in: workspace), let place = manager.location(of: workspace.id) {
            return WindowFocusPlan(
                index: place.index, workspace: adopted,
                switchesWorkspace: workspace.id != manager.currentID,
                revealsHiddenWorkspace: !manager.activeIDs.contains(workspace.id)
            )
        }
    }
    return nil
}
