import CoreGraphics
import Foundation

/// Niri `consume-or-expel-window-left/right` on workspace state.
///
/// - A window sharing its column (>1 windows) is EXPELLED into a fresh column
///   on the requested side; the new column takes the default width.
/// - A window alone in its column is CONSUMED by the neighbouring column on
///   that side, appended at its bottom; the emptied column is removed.
/// - Focus follows the window. A consumed window keeps its height weight; an
///   expelled window is alone in its column, so its weight is dropped.
///
/// Up/down, a lone window with no neighbour, and invalid focus are NO-OPs:
/// the workspace comes back unchanged (callers detect that with `==`).
public func consumeOrExpelWindow(in workspace: Workspace, direction: FocusDirection) -> Workspace {
    guard direction == .left || direction == .right,
          workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count
    else {
        return workspace
    }
    let source = workspace.focusedColumn
    var column = workspace.columns[source]
    guard column.focusedWindowIndex >= 0, column.focusedWindowIndex < column.windows.count else {
        return workspace
    }
    let window = column.windows[column.focusedWindowIndex]
    var next = workspace

    if column.windows.count > 1 {
        column.windows.remove(at: column.focusedWindowIndex)
        column.heightWeights.removeValue(forKey: window)
        column.focusedWindowIndex = min(column.focusedWindowIndex, column.windows.count - 1)
        next.columns[source] = column
        let freshID = ColumnID((next.columns.map(\.id.rawValue).max() ?? 0) + 1)
        let expelled = Column(id: freshID, width: 0, windows: [window])
        // Left of the source keeps the source's index; right follows it.
        let target = direction == .left ? source : source + 1
        next.columns.insert(expelled, at: target)
        next.focusedColumn = target
        next.focusedWindow = window
        return next
    }

    let neighbor = direction == .left ? source - 1 : source + 1
    guard neighbor >= 0, neighbor < workspace.columns.count else {
        return workspace
    }
    let weight = column.heightWeights[window]
    next.columns.remove(at: source)
    // Removing the source shifts a right neighbour down onto `source`.
    let target = direction == .left ? neighbor : source
    next.columns[target].windows.append(window)
    if let weight {
        next.columns[target].heightWeights[window] = weight
    }
    next.columns[target].focusedWindowIndex = next.columns[target].windows.count - 1
    next.focusedColumn = target
    next.focusedWindow = window
    return next
}
