import Foundation

/// Plan §12 move operations on workspace state. Focus and move are separate
/// concepts: focus only changes what is selected, move rearranges windows.
///
/// - Left/right move the focused window to the adjacent column (appended at
///   its end). Past the strip edge a new column is created — the strip
///   grows instead of refusing. A source column left empty is removed.
/// - Up/down reorder inside the column; stack edges are NO-OP.
/// - The moved window keeps focus; the destination column adopts it.
/// - New column IDs derive deterministically (`max + 1`), so moves stay
///   pure and testable. Height weights travel with the window.
///
/// Invalid states (bad column/index, empty source column) are NO-OP: the
/// workspace returns unchanged. Callers detect that with `==`.
public func moveWindow(in workspace: Workspace, direction: FocusDirection) -> Workspace {
    var next = workspace
    guard next.focusedColumn >= 0, next.focusedColumn < next.columns.count else {
        return workspace
    }
    var column = next.columns[next.focusedColumn]
    guard column.focusedWindowIndex >= 0, column.focusedWindowIndex < column.windows.count else {
        return workspace
    }

    switch direction {
    case .up, .down:
        let delta = direction == .up ? -1 : 1
        let target = column.focusedWindowIndex + delta
        guard target >= 0, target < column.windows.count else {
            return workspace
        }
        column.windows.swapAt(column.focusedWindowIndex, target)
        column.focusedWindowIndex = target
        next.columns[next.focusedColumn] = column
        next.focusedWindow = column.focusedWindowID
        return next
    case .left, .right:
        let window = column.windows[column.focusedWindowIndex]
        let weight = column.heightWeights[window]
        column.windows.remove(at: column.focusedWindowIndex)
        if weight != nil {
            column.heightWeights.removeValue(forKey: window)
        }
        let source = next.focusedColumn
        let removed = column.windows.isEmpty
        if removed {
            next.columns.remove(at: source)
        } else {
            next.columns[source] = column
        }
        // Fresh IDs derive deterministically so moves stay pure.
        let freshID = ColumnID((next.columns.map(\.id.rawValue).max() ?? 0) + 1)
        let target: Int
        if direction == .left, source > 0 {
            // The left neighbor keeps index `source - 1` whether or not the
            // emptied source (at `source`) was removed.
            target = source - 1
            adopt(window, weight: weight, into: &next, column: target)
        } else if direction == .right {
            // Without removal the right neighbor is at `source + 1`; with
            // removal it slid into `source`.
            let candidate = removed ? source : source + 1
            if candidate < next.columns.count {
                target = candidate
                adopt(window, weight: weight, into: &next, column: target)
            } else {
                target = next.columns.count
                var created = Column(id: freshID, width: 0)
                adopt(window, weight: weight, into: &created)
                next.columns.append(created)
            }
        } else {
            target = 0
            var created = Column(id: freshID, width: 0)
            adopt(window, weight: weight, into: &created)
            next.columns.insert(created, at: 0)
        }
        next.focusedColumn = target
        next.focusedWindow = window
        return next
    }
}

/// Append `window` to a column, adopt focus and carry its height weight.
private func adopt(
    _ window: WindowID,
    weight: CGFloat?,
    into workspace: inout Workspace,
    column target: Int
) {
    workspace.columns[target].windows.append(window)
    if let weight {
        workspace.columns[target].heightWeights[window] = weight
    }
    workspace.columns[target].focusedWindowIndex = workspace.columns[target].windows.count - 1
}

private func adopt(_ window: WindowID, weight: CGFloat?, into column: inout Column) {
    column.windows.append(window)
    if let weight {
        column.heightWeights[window] = weight
    }
    column.focusedWindowIndex = column.windows.count - 1
}
