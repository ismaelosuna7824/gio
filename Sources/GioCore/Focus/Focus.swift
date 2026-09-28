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
/// Missing targets are NO-OP: the workspace is returned unchanged. Callers
/// detect that with `==`. Out-of-range indices are also NO-OP — focus never
/// invents a position.
///
/// Pipeline note (plan §11): after a change the caller runs `ensureVisible`
/// (Viewport), then Layout, then the Reconciler. That composition lands in
/// the 0.1 assembly (RW-09); this unit only moves focus.
public func moveFocus(in workspace: Workspace, direction: FocusDirection) -> Workspace {
    var next = workspace
    switch direction {
    case .left:
        guard next.focusedColumn > 0, next.focusedColumn - 1 < next.columns.count else {
            return workspace
        }
        next.focusedColumn -= 1
        next.focusedWindow = next.columns[next.focusedColumn].focusedWindowID
    case .right:
        guard next.focusedColumn >= 0, next.focusedColumn + 1 < next.columns.count else {
            return workspace
        }
        next.focusedColumn += 1
        next.focusedWindow = next.columns[next.focusedColumn].focusedWindowID
    case .up, .down:
        guard next.focusedColumn >= 0, next.focusedColumn < next.columns.count else {
            return workspace
        }
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
