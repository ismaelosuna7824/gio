import Foundation

/// Niri `move-column-left/right` (FI-06): swap the focused column with its
/// neighbour. The column keeps its composition, width and height weights,
/// and the same window keeps focus; only the strip order changes. Up/down,
/// the strip edge and invalid focus are NO-OPs (callers detect that with `==`).
public func moveColumn(in workspace: Workspace, direction: FocusDirection) -> Workspace {
    guard direction == .left || direction == .right,
          workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count
    else {
        return workspace
    }
    let source = workspace.focusedColumn
    let target = direction == .left ? source - 1 : source + 1
    guard target >= 0, target < workspace.columns.count else {
        return workspace
    }
    var next = workspace
    next.columns.swapAt(source, target)
    next.focusedColumn = target
    return next
}
