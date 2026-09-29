import Foundation

/// One window's focus facts from a scan. `isFocused` is the OWNING APP's
/// `AXFocusedWindow`, so every running app reports one focused window.
public struct FocusCandidate: Equatable, Sendable {
    public let id: WindowID
    public let isFocused: Bool
    public let isMinimized: Bool

    public init(id: WindowID, isFocused: Bool, isMinimized: Bool) {
        self.id = id
        self.isFocused = isFocused
        self.isMinimized = isMinimized
    }
}

/// The window the user is actually on: the focused window of the frontmost
/// app. Adopting "the last app that reported a focused window" scrolled the
/// strip to an arbitrary column on every rescan and rewrote every window.
public func adoptableFocus(among candidates: [FocusCandidate], frontmostPID: pid_t?) -> WindowID? {
    guard let frontmostPID else {
        return nil
    }
    return candidates.first {
        $0.id.pid == frontmostPID && $0.isFocused && !$0.isMinimized
    }?.id
}

/// The workspace with `id` as its focus, or nil when the window is not in
/// any of its columns. Adopting the window that is already focused returns
/// an equal workspace, so callers can compare to detect a change.
public func adoptingFocus(_ id: WindowID, in workspace: Workspace) -> Workspace? {
    guard let row = workspace.columns.firstIndex(where: { $0.windows.contains(id) }),
          let index = workspace.columns[row].windows.firstIndex(of: id)
    else {
        return nil
    }
    var adopted = workspace
    adopted.focusedColumn = row
    adopted.columns[row].focusedWindowIndex = index
    adopted.focusedWindow = id
    return adopted
}
