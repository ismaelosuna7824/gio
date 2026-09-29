import CoreGraphics
import Foundation

/// Niri's default `preset-column-widths`: a third, a half, two thirds.
public let defaultPresetColumnWidths: [ColumnWidthSpec] = [
    .proportion(0.33333), .proportion(0.5), .proportion(0.66667),
]

/// Tolerance when comparing resolved widths (points); a preset within this
/// of the current width counts as "the same width", so cycling always moves.
private let widthEpsilon: CGFloat = 0.5

/// Niri `switch-preset-column-width`: give the focused column the first
/// preset strictly wider than its current width on this viewport, wrapping
/// to the first preset when none is wider. An empty preset list or a missing
/// focused column is a NO-OP (the workspace comes back unchanged).
public func switchPresetColumnWidth(
    in workspace: Workspace,
    presets: [ColumnWidthSpec],
    config: LayoutConfig,
    viewportWidth: CGFloat
) -> Workspace {
    guard !presets.isEmpty,
          workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count
    else {
        return workspace
    }
    var next = workspace
    let current = config.resolvedWidth(
        of: next.columns[next.focusedColumn].widthSpec, viewportWidth: viewportWidth
    )
    let chosen = presets.first {
        config.resolvedWidth(of: $0, viewportWidth: viewportWidth) > current + widthEpsilon
    } ?? presets[0]
    next.columns[next.focusedColumn].widthSpec = chosen
    return next
}

/// Niri `set-column-width "+10%"` / `"-10%"`: move the focused column's
/// proportion by `fraction` (0.1 = 10% of the viewport strip), clamped
/// between the minimum column width and the full strip. The result is always
/// a proportion so it keeps adapting across displays.
public func stepFocusedColumnWidth(
    in workspace: Workspace,
    by fraction: CGFloat,
    config: LayoutConfig,
    viewportWidth: CGFloat
) -> Workspace {
    guard workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count else {
        return workspace
    }
    let strip = viewportWidth - config.padding * 2 + config.gap
    guard strip > 0 else {
        return workspace
    }
    var next = workspace
    let current = config.resolvedWidth(
        of: next.columns[next.focusedColumn].widthSpec, viewportWidth: viewportWidth
    )
    let smallest = min((config.minimumColumnWidth + config.gap) / strip, 1)
    let proposed = (current + config.gap) / strip + fraction
    next.columns[next.focusedColumn].widthSpec = .proportion(min(max(proposed, smallest), 1))
    return next
}

/// Niri `maximize-column`: the focused column takes the full strip width
/// (proportion 1.0); toggling again restores the width it had before. Any
/// other width change forgets the saved width (see `Column.widthSpec`).
public func toggleMaximizeFocusedColumn(in workspace: Workspace) -> Workspace {
    guard workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count else {
        return workspace
    }
    var next = workspace
    var column = next.columns[next.focusedColumn]
    if let saved = column.savedWidthSpec {
        column.widthSpec = saved
    } else {
        let previous = column.widthSpec
        column.widthSpec = .proportion(1)
        column.savedWidthSpec = previous
    }
    next.columns[next.focusedColumn] = column
    return next
}
