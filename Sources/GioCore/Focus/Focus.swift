import Foundation

/// Plan §11 directions. Initial bindings (wired in Phase 13) are Alt+HJKL;
/// this layer only moves focus and never touches hotkeys.
public enum FocusDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// Plan §11 focus navigation on workspace state. Horizontal moves switch
/// columns (`H` previous, `L` next); vertical moves switch windows inside
/// the focused column (`K` previous, `J` next). Each column remembers its
/// own focused window, so leaving and returning restores it.
///
/// WC-12: horizontal moves skip columns whose windows are all non-tiled
/// under `modes` (floating, fullscreen, minimized); empty columns stay
/// reachable. Unknown IDs count as tiled, so an empty map skips nothing.
///
/// Missing targets are NO-OP: the workspace is returned unchanged. Callers
/// detect that with `==`. Out-of-range indices are also NO-OP — focus never
/// invents a position.
///
/// Pipeline note (plan §11): after a change the caller runs `ensureVisible`
/// (Viewport), then Layout, then the Reconciler. That composition lands in
/// the 0.1 assembly (RW-09); this unit only moves focus.
public func moveFocus(
    in workspace: Workspace, direction: FocusDirection, modes: [WindowID: WindowMode]
) -> Workspace {
    guard workspace.columns.indices.contains(workspace.focusedColumn) else {
        return workspace
    }
    var next = workspace
    switch direction {
    case .left, .right:
        let ahead = direction == .left
            ? Array(workspace.columns.indices[..<workspace.focusedColumn].reversed())
            : Array(workspace.columns.indices[(workspace.focusedColumn + 1)...])
        guard let target = ahead.first(where: { isNavigable(workspace.columns[$0], modes: modes) }) else {
            return workspace
        }
        next.focusedColumn = target
        next.focusedWindow = next.columns[target].focusedWindowID
    case .up, .down:
        var column = next.columns[next.focusedColumn]
        let delta = direction == .up ? -1 : 1
        let target = column.focusedWindowIndex + delta
        guard target >= 0, target < column.windows.count else {
            return workspace
        }
        column.focusedWindowIndex = target
        next.columns[next.focusedColumn] = column
        next.focusedWindow = column.focusedWindowID
    }
    return next
}

func isNavigable(_ column: Column, modes: [WindowID: WindowMode]) -> Bool {
    column.windows.isEmpty || column.windows.contains { isTiled($0, modes: modes) }
}
