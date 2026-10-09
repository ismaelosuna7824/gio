import CoreGraphics
import Foundation

/// NC-08 niri's default `preset-window-heights`: a third, a half, two thirds
/// of the usable height (same proportion/points rule as the widths).
public let defaultPresetWindowHeights: [ColumnWidthSpec] = [
    .proportion(0.33333), .proportion(0.5), .proportion(0.66667),
]

/// NC-08: no height action squeezes a stacked window below this (points):
/// a title bar and a few lines stay visible.
public let minimumWindowHeight: CGFloat = 100

/// Tolerance when comparing heights (points); a preset within this of the
/// current height counts as "the same height", so cycling always moves.
private let heightEpsilon: CGFloat = 0.5

/// Niri `switch-preset-window-height`: give the focused window of a stacked
/// column the first preset strictly taller than its current height, wrapping
/// to the first preset when none is. Proportions resolve like widths, over
/// the usable height: `p * (viewport - 2*padding + gap) - gap`, so two 0.5
/// windows fill the column exactly. The result is clamped so every window
/// keeps `minimumWindowHeight`. No-ops (unchanged workspace): no presets, no
/// focused window, a lone window (it always fills its column), a column too
/// short to give every window the minimum, or no change.
public func switchPresetWindowHeight(
    in workspace: Workspace,
    presets: [ColumnWidthSpec],
    config: LayoutConfig,
    viewportHeight: CGFloat
) -> Workspace {
    guard !presets.isEmpty, let stack = HeightStack(workspace, config: config, viewportHeight: viewportHeight) else {
        return workspace
    }
    let current = stack.focusedHeight
    let chosen = presets.first {
        stack.resolved($0) > current + heightEpsilon
    } ?? presets[0]
    return stack.setting(stack.resolved(chosen), in: workspace)
}

/// Niri `set-window-height "+10%"` / `"-10%"`: move the focused window's
/// height by `fraction` of the usable height (0.1 = 10%), clamped so every
/// window of the column keeps `minimumWindowHeight`. Same no-ops as
/// `switchPresetWindowHeight`.
public func stepFocusedWindowHeight(
    in workspace: Workspace,
    by fraction: CGFloat,
    config: LayoutConfig,
    viewportHeight: CGFloat
) -> Workspace {
    guard let stack = HeightStack(workspace, config: config, viewportHeight: viewportHeight) else {
        return workspace
    }
    return stack.setting(stack.focusedHeight + fraction * stack.strip, in: workspace)
}

/// Niri `reset-window-height`, on Gio's relative weights: every window of
/// the focused column gets an equal share again (weights are relative, so
/// "automatic" for one window only means something next to the others).
/// Equal shares already, or no focused column: a no-op.
public func resetWindowHeights(in workspace: Workspace) -> Workspace {
    guard let column = workspace.focusedColumnRef, !column.heightWeights.isEmpty else {
        return workspace
    }
    var next = workspace
    next.columns[next.focusedColumn].heightWeights = [:]
    return next
}

/// The focused column's height arithmetic, mirroring the layout engine:
/// `available` is what the windows share after padding and the gaps between
/// them, split by weight (absent = 1).
private struct HeightStack {
    let column: Column
    let focused: Int
    let config: LayoutConfig
    /// Usable height plus one gap: the proportion base (like the width strip).
    let strip: CGFloat
    let available: CGFloat

    init?(_ workspace: Workspace, config: LayoutConfig, viewportHeight: CGFloat) {
        guard let column = workspace.focusedColumnRef, column.windows.count > 1,
              column.focusedWindowIndex >= 0, column.focusedWindowIndex < column.windows.count
        else {
            return nil
        }
        let usable = viewportHeight - config.padding * 2
        let available = usable - config.gap * CGFloat(column.windows.count - 1)
        guard available >= minimumWindowHeight * CGFloat(column.windows.count) else {
            return nil
        }
        self.column = column
        self.focused = column.focusedWindowIndex
        self.config = config
        self.strip = usable + config.gap
        self.available = available
    }

    private func weight(_ id: WindowID) -> CGFloat {
        column.heightWeights[id] ?? 1
    }

    private var focusedID: WindowID { column.windows[focused] }

    private var otherWeights: CGFloat {
        column.windows.filter { $0 != focusedID }.reduce(0) { $0 + weight($1) }
    }

    var focusedHeight: CGFloat {
        available * weight(focusedID) / (weight(focusedID) + otherWeights)
    }

    /// A preset's height in this column (`.standard`: an equal share).
    func resolved(_ spec: ColumnWidthSpec) -> CGFloat {
        switch spec {
        case .standard:
            return available / CGFloat(column.windows.count)
        case .proportion(let value):
            return value * strip - config.gap
        case .points(let value):
            return value
        }
    }

    /// The workspace with the focused window at `height` (clamped). The
    /// other windows keep their weights, so they split the rest as before.
    func setting(_ height: CGFloat, in workspace: Workspace) -> Workspace {
        let others = CGFloat(column.windows.count - 1)
        let clamped = min(max(height, minimumWindowHeight), available - minimumWindowHeight * others)
        guard abs(clamped - focusedHeight) > heightEpsilon else {
            return workspace
        }
        var next = workspace
        next.columns[next.focusedColumn].heightWeights[focusedID] = clamped * otherWeights / (available - clamped)
        return next
    }
}
