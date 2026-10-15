import Foundation

/// NC-09 niri `focus-column-first`: focus the leftmost column (its own
/// focused window). WC-12: the leftmost column `moveFocus` could reach,
/// skipping non-tiled columns under `modes`. Already there or no columns:
/// a no-op.
public func focusColumnFirst(in workspace: Workspace, modes: [WindowID: WindowMode]) -> Workspace {
    let first = workspace.columns.firstIndex { isNavigable($0, modes: modes) }
    return focusColumn(at: first, in: workspace)
}

/// NC-09 niri `focus-column-last`.
public func focusColumnLast(in workspace: Workspace, modes: [WindowID: WindowMode]) -> Workspace {
    let last = workspace.columns.lastIndex { isNavigable($0, modes: modes) }
    return focusColumn(at: last, in: workspace)
}

private func focusColumn(at index: Int?, in workspace: Workspace) -> Workspace {
    guard let index, index != workspace.focusedColumn else {
        return workspace
    }
    var next = workspace
    next.focusedColumn = index
    next.focusedWindow = next.columns[index].focusedWindowID
    return next
}

/// NC-09 niri `move-column-to-first`: the focused column moves to the start
/// of the strip with its windows, width and heights; the same window keeps
/// focus. Already first or invalid focus: a no-op.
public func moveColumnToFirst(in workspace: Workspace) -> Workspace {
    moveFocusedColumn(to: 0, in: workspace)
}

/// NC-09 niri `move-column-to-last`.
public func moveColumnToLast(in workspace: Workspace) -> Workspace {
    moveFocusedColumn(to: workspace.columns.count - 1, in: workspace)
}

private func moveFocusedColumn(to index: Int, in workspace: Workspace) -> Workspace {
    let source = workspace.focusedColumn
    guard source >= 0, source < workspace.columns.count, index >= 0, index != source else {
        return workspace
    }
    var next = workspace
    next.columns.insert(next.columns.remove(at: source), at: index)
    next.focusedColumn = index
    return next
}

/// NC-09 niri `swap-window-left/right`: the focused window trades places
/// with the focused window of the neighbouring column (niri swaps with that
/// column's active tile, not the same row). Columns stay where they are with
/// their widths and focused rows; height weights travel with the windows and
/// focus follows the window. Two lone windows: the same as `moveColumn` (the
/// column moves, width included, like niri). Up/down, the strip edge and
/// invalid focus are NO-OPs.
public func swapWindow(in workspace: Workspace, direction: FocusDirection) -> Workspace {
    guard direction == .left || direction == .right,
          let sourceColumn = workspace.focusedColumnRef,
          sourceColumn.focusedWindowID != nil
    else {
        return workspace
    }
    let source = workspace.focusedColumn
    let target = direction == .left ? source - 1 : source + 1
    guard target >= 0, target < workspace.columns.count,
          workspace.columns[target].focusedWindowID != nil
    else {
        return workspace
    }
    if sourceColumn.windows.count == 1, workspace.columns[target].windows.count == 1 {
        return moveColumn(in: workspace, direction: direction)
    }
    var next = workspace
    var from = sourceColumn
    var into = next.columns[target]
    let (fromRow, intoRow) = (from.focusedWindowIndex, into.focusedWindowIndex)
    let (moving, staying) = (from.windows[fromRow], into.windows[intoRow])
    from.windows[fromRow] = staying
    into.windows[intoRow] = moving
    let (movingWeight, stayingWeight) = (from.heightWeights.removeValue(forKey: moving), into.heightWeights.removeValue(forKey: staying))
    from.heightWeights[staying] = stayingWeight
    into.heightWeights[moving] = movingWeight
    next.columns[source] = from
    next.columns[target] = into
    next.focusedColumn = target
    next.focusedWindow = moving
    return next
}
