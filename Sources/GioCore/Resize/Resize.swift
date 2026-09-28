import CoreGraphics
import Foundation

/// Plan §13 resize operations on workspace state. Resize modifies the model;
/// the engine renders it and the reconciler writes it (Phase 8).
///
/// - Column width is absolute points. Non-positive widths render as the
///   engine default, so `resetFocusedColumnWidth` stores zero.
/// - Window heights are relative weights (default 1.0, absent means 1.0).
///   `resizeFocusedWindowHeight` multiplies by a factor — repeated keypresses
///   compound — floored at 0.2 so windows stay visible. Reset removes the
///   entry, restoring the default.
/// - Resize mode itself (Alt+R, §13) is a hotkey-layer concern (Phase 13);
///   these units are mode-agnostic.
///
/// Invalid states are NO-OP: the workspace returns unchanged.
public func resizeFocusedColumnWidth(in workspace: Workspace, delta: CGFloat) -> Workspace {
    var next = workspace
    guard next.focusedColumn >= 0, next.focusedColumn < next.columns.count else {
        return workspace
    }
    next.columns[next.focusedColumn].width = max(0, next.columns[next.focusedColumn].width + delta)
    return next
}

public func resetFocusedColumnWidth(in workspace: Workspace) -> Workspace {
    var next = workspace
    guard next.focusedColumn >= 0, next.focusedColumn < next.columns.count else {
        return workspace
    }
    next.columns[next.focusedColumn].width = 0
    return next
}

public func resizeFocusedWindowHeight(in workspace: Workspace, factor: CGFloat) -> Workspace {
    var next = workspace
    guard factor > 0,
          next.focusedColumn >= 0, next.focusedColumn < next.columns.count
    else {
        return workspace
    }
    var column = next.columns[next.focusedColumn]
    guard column.focusedWindowIndex >= 0, column.focusedWindowIndex < column.windows.count else {
        return workspace
    }
    let id = column.windows[column.focusedWindowIndex]
    column.heightWeights[id] = max(0.2, (column.heightWeights[id] ?? 1) * factor)
    next.columns[next.focusedColumn] = column
    return next
}

public func resetFocusedWindowHeight(in workspace: Workspace) -> Workspace {
    var next = workspace
    guard next.focusedColumn >= 0, next.focusedColumn < next.columns.count else {
        return workspace
    }
    var column = next.columns[next.focusedColumn]
    guard column.focusedWindowIndex >= 0, column.focusedWindowIndex < column.windows.count else {
        return workspace
    }
    column.heightWeights.removeValue(forKey: column.windows[column.focusedWindowIndex])
    next.columns[next.focusedColumn] = column
    return next
}
