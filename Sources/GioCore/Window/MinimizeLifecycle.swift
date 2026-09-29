import Foundation

/// Minimize keeps the window registered and in its column (position memory);
/// layout filtering happens through `reconcileTileability`, which reports
/// minimized windows as non-tiled. These functions only maintain the flag
/// and the focus that must never rest on a hidden window.

/// Mark a window minimized and, where it held focus, hand focus to the
/// nearest visible window: same column first, then columns to the right,
/// then to the left. Returns false for unknown windows.
@discardableResult
public func minimizeWindow(
    _ id: WindowID,
    registry: WindowRegistry,
    manager: inout WorkspaceManager
) -> Bool {
    guard (try? registry.setMinimized(true, for: id)) != nil else {
        return false
    }
    for index in WorkspaceManager.range {
        guard var workspace = manager.workspace(index),
              workspace.focusedWindow == id
        else {
            continue
        }
        let visible: (WindowID) -> Bool = { registry.find($0)?.isMinimized == false }
        let start = workspace.focusedColumn
        let order = [0] + (1...max(1, workspace.columns.count)).flatMap { [$0, -$0] }
        for offset in order {
            let column = start + offset
            guard workspace.columns.indices.contains(column) else {
                continue
            }
            let windows = workspace.columns[column].windows
            let current = workspace.columns[column].focusedWindowID
            guard let pick = current.flatMap({ visible($0) ? $0 : nil }) ?? windows.first(where: visible)
            else {
                continue
            }
            workspace.focusedColumn = column
            workspace.columns[column].focusedWindowIndex = windows.firstIndex(of: pick)!
            workspace.focusedWindow = pick
            manager.update(workspace)
            break
        }
    }
    return true
}

/// Clear the minimized flag and focus the window in its remembered column.
/// A window whose column is gone is inserted as a new column right after
/// the current workspace's focused column. Returns false for unknown windows.
@discardableResult
public func restoreWindow(
    _ id: WindowID,
    registry: WindowRegistry,
    manager: inout WorkspaceManager
) -> Bool {
    guard (try? registry.setMinimized(false, for: id)) != nil else {
        return false
    }
    for index in WorkspaceManager.range {
        guard var workspace = manager.workspace(index),
              let column = workspace.columns.firstIndex(where: { $0.windows.contains(id) })
        else {
            continue
        }
        workspace.focusedColumn = column
        workspace.columns[column].focusedWindowIndex =
            workspace.columns[column].windows.firstIndex(of: id)!
        workspace.focusedWindow = id
        manager.update(workspace)
        return true
    }
    var workspace = manager.currentWorkspace()
    let at = workspace.columns.isEmpty ? 0 : min(workspace.focusedColumn + 1, workspace.columns.count)
    workspace.columns.insert(
        Column(
            id: ColumnID((workspace.columns.map(\.id.rawValue).max() ?? 0) + 1),
            width: 0, windows: [id]
        ),
        at: at
    )
    workspace.focusedColumn = at
    workspace.focusedWindow = id
    manager.update(workspace)
    return true
}
