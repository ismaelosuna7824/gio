import Foundation

extension WorkspaceManager {
    /// WO-02: a window tile dragged in the workspace overview of `display`
    /// and dropped at `move.column` of the strip `move.workspace`. Columns
    /// count as the overview shows them: only tiled windows (`modes`, the
    /// layout's; a minimized window is non-tiled there), columns without one
    /// hidden.
    ///
    /// - A window alone in its column carries the column (width, saved
    ///   width, heights). Within its own workspace that is a reorder;
    ///   dropped at its own place it is `.unchanged`.
    /// - A window stacked with others leaves its column (the rest stay) and
    ///   becomes its own column there, as wide as the column it left.
    /// - Into another workspace of the stack: the source repairs its focus as
    ///   when a window leaves (the column's next window, else the column on
    ///   the right, else the left); the target keeps its focused window
    ///   unless it was empty (the window becomes its focus). Nothing
    ///   follows: the current workspace and display stay. `update` keeps the
    ///   stack invariants (a filled spare grows a new one, an emptied
    ///   inactive dynamic workspace is removed).
    /// - DW-01: a dwindle workspace's columns are its membership list, so the
    ///   window joins it at `column`, but the tree decides the place: a new
    ///   member splits the selected (focused) leaf and the columns follow
    ///   the tree's leaf order, so it lands right after the focused tile; a
    ///   reorder within a dwindle workspace keeps the tree's order
    ///   (`.unchanged`). A pending dwindle preselection is used by it.
    ///
    /// `.refused` (nothing changes) for an unknown, non-tiled (floating,
    /// fullscreen, minimized) window, a window not on `display`'s stack, or
    /// a workspace or column outside the stack or strip. Passive: no focus
    /// intent; the caller reflows.
    @discardableResult
    public mutating func moveWindowFromOverview(
        _ move: OverviewMove, on display: DisplayID, modes: [WindowID: WindowMode]
    ) -> OverviewMoveResult {
        let stack = self.stack(on: display)
        guard let id = WindowID(text: move.windowID), isTiled(id, modes: modes),
              move.workspace >= 1, move.workspace <= stack.count,
              let source = stack.first(where: { $0.windows.contains(id) }),
              let columnIndex = source.columns.firstIndex(where: { $0.windows.contains(id) })
        else {
            return .refused
        }
        let target = stack[move.workspace - 1]
        let shown = target.columns.indices.filter { index in
            target.columns[index].windows.contains { isTiled($0, modes: modes) }
        }
        guard move.column >= 0, move.column <= shown.count else {
            return .refused
        }
        // Before the shown column `move.column`, else after every column.
        let position = move.column < shown.count ? shown[move.column] : target.columns.count
        var origin = source
        let originFocus = origin.focusedColumnRef?.id
        let lone = origin.columns[columnIndex].windows.count == 1
        let carried: Column
        if lone {
            carried = origin.columns.remove(at: columnIndex)
        } else {
            carried = leave(id, column: &origin.columns[columnIndex])
        }

        if target.id == source.id {
            var landing = position
            if lone {
                if landing > columnIndex {
                    landing -= 1
                }
                guard landing != columnIndex else {
                    return .unchanged
                }
                origin.columns.insert(carried, at: landing)
            } else {
                origin.columns.insert(relabeled(carried, in: origin), at: landing)
            }
            // What `update` stores: a dwindle tree keeps its leaf order, so a
            // reorder there comes back as it was. Compared before writing, as
            // any write renews the inactive trailing spare (`normalize`).
            var written = refocused(origin, focusedColumnID: originFocus, vacated: columnIndex)
            written.reconcileDwindle(splitRatio: layoutDefaults.splitRatio)
            guard written != source else {
                return .unchanged
            }
            update(written)
            return .moved
        }

        var destination = target
        let destinationFocus = destination.focusedColumnRef?.id
        let wasEmpty = destination.columns.isEmpty
        destination.columns.insert(relabeled(carried, in: destination), at: position)
        if wasEmpty {
            destination.focusedColumn = position
            destination.focusedWindow = id
        } else {
            destination = refocused(destination, focusedColumnID: destinationFocus, vacated: destination.focusedColumn)
        }
        // The target first: an emptied source written first would prune an
        // empty inactive target (the spare) and the window would be lost.
        update(destination)
        update(refocused(origin, focusedColumnID: originFocus, vacated: columnIndex))
        return .moved
    }
}

/// Take `id` out of its stacked `column` (its focus repaired as
/// `WorkspaceManager`'s detach does) and return it as its own column with
/// the column's width spec and its height weight. The id is a placeholder.
private func leave(_ id: WindowID, column: inout Column) -> Column {
    let row = column.windows.firstIndex(of: id)!
    let weight = column.heightWeights.removeValue(forKey: id)
    column.windows.remove(at: row)
    if column.focusedWindowIndex == row {
        column.focusedWindowIndex = min(row, column.windows.count - 1)
    } else if column.focusedWindowIndex > row {
        column.focusedWindowIndex -= 1
    }
    var single = Column(id: ColumnID(0), width: 0, windows: [id], widthSpec: column.widthSpec)
    if let weight {
        single.heightWeights[id] = weight
    }
    return single
}

/// `column` under an id unused in `workspace`.
private func relabeled(_ column: Column, in workspace: Workspace) -> Column {
    var placed = Column(
        id: ColumnID((workspace.columns.map(\.id.rawValue).max() ?? 0) + 1), width: 0,
        windows: column.windows, focusedWindowIndex: column.focusedWindowIndex,
        heightWeights: column.heightWeights, widthSpec: column.widthSpec
    )
    placed.savedWidthSpec = column.savedWidthSpec
    return placed
}

/// Point `focusedColumn` back at the focus after columns moved: the focused
/// window's column; else (it left) the column that was focused, now on its
/// own focused window; else (that column left too) the column now at
/// `vacated`, else the last.
private func refocused(_ workspace: Workspace, focusedColumnID: ColumnID?, vacated: Int) -> Workspace {
    var result = workspace
    guard !result.columns.isEmpty else {
        result.focusedColumn = 0
        result.focusedWindow = nil
        return result
    }
    if let window = result.focusedWindow, let index = result.columns.firstIndex(where: { $0.windows.contains(window) }) {
        result.focusedColumn = index
        return result
    }
    let index = focusedColumnID.flatMap { id in result.columns.firstIndex { $0.id == id } }
        ?? min(max(vacated, 0), result.columns.count - 1)
    result.focusedColumn = index
    if result.focusedWindow != nil {
        result.focusedWindow = result.columns[index].focusedWindowID
    }
    return result
}
