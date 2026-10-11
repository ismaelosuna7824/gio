import CoreGraphics
import Foundation

/// DW-02: what the dwindle actions need to see the tiles: the usable frame
/// of the display showing the workspace, the window modes (a floating or
/// minimized window has no tile) and the layout config (padding, gap,
/// `[dwindle]`). Split orientations follow the rectangles, so neighbours
/// and "the horizontal split" depend on this geometry.
public struct DwindleGeometry: Equatable, Sendable {
    public var viewport: CGRect
    public var modes: [WindowID: WindowMode]
    public var config: LayoutConfig

    public init(viewport: CGRect, modes: [WindowID: WindowMode] = [:], config: LayoutConfig = LayoutConfig()) {
        self.viewport = viewport
        self.modes = modes
        self.config = config
    }

    /// Unknown display geometry (a caller without frames): a 1800x1000 area.
    public static func fallback(_ frame: CGRect?) -> DwindleGeometry {
        DwindleGeometry(viewport: frame ?? CGRect(x: 0, y: 0, width: 1800, height: 1000))
    }
}

/// DW-02: the outcome of a dwindle move (swap with the geometric neighbour).
public enum DwindleStep: Equatable, Sendable {
    /// The focused window traded tiles with its neighbour.
    case moved(Workspace)
    /// No tile that way: the workspace edge (Move Edge may cross displays).
    case atEdge
    /// Nothing to move (not dwindle, no focused window, no tile at all).
    case unchanged
}

// MARK: - Geometry

/// The tiles the actions measure: every tiled leaf, plus the focused
/// window's own leaf even when it is not tiled (a focused floating window
/// still navigates from where its tile would be), with fullscreen windows
/// in their tiles. Nil when the geometry cannot be laid out.
func dwindleActionLayout(_ workspace: Workspace, geometry: DwindleGeometry) -> DwindleLayout? {
    var modes = geometry.modes.mapValues { $0 == .fullscreen ? WindowMode.tiled : $0 }
    if let focused = workspace.focusedWindow {
        modes[focused] = .tiled
    }
    return try? DwindleLayoutEngine(config: geometry.config).layout(
        workspace.dwindle, viewport: geometry.viewport, modes: modes
    )
}

/// The tile next to `frame` in `direction` (Cocoa: up is larger y): a tile
/// entirely past the matching edge (1 pt tolerance) that overlaps it on the
/// other axis; the nearest edge wins, then the larger overlap, then the
/// closer centre, then leaf order. Nil at the workspace edge.
func dwindleNeighbour(
    of id: WindowID, direction: FocusDirection, frames: [WindowID: CGRect], order: [WindowID]
) -> WindowID? {
    guard let origin = frames[id] else {
        return nil
    }
    let tolerance: CGFloat = 1
    var best: (id: WindowID, distance: CGFloat, overlap: CGFloat, offset: CGFloat)?
    for candidate in order where candidate != id {
        guard let frame = frames[candidate] else {
            continue
        }
        let distance: CGFloat
        let overlap: CGFloat
        let offset: CGFloat
        switch direction {
        case .left, .right:
            distance = direction == .left ? origin.minX - frame.maxX : frame.minX - origin.maxX
            overlap = min(origin.maxY, frame.maxY) - max(origin.minY, frame.minY)
            offset = abs(frame.midY - origin.midY)
        case .up, .down:
            distance = direction == .down ? origin.minY - frame.maxY : frame.minY - origin.maxY
            overlap = min(origin.maxX, frame.maxX) - max(origin.minX, frame.minX)
            offset = abs(frame.midX - origin.midX)
        }
        guard distance >= -tolerance, overlap > tolerance else {
            continue
        }
        if let current = best {
            let better = distance < current.distance - tolerance
                || (abs(distance - current.distance) <= tolerance
                    && (overlap > current.overlap + tolerance
                        || (abs(overlap - current.overlap) <= tolerance && offset < current.offset - tolerance)))
            if !better {
                continue
            }
        }
        best = (candidate, distance, overlap, offset)
    }
    return best?.id
}

/// `workspace` with `id` focused (its column and window), the selection
/// following it.
private func focusing(_ id: WindowID, in workspace: Workspace) -> Workspace {
    var next = adoptingFocus(id, in: workspace) ?? workspace
    next.reconcileDwindle(splitRatio: 1)
    return next
}

/// The path of the split that holds the focused leaf, nil without one.
private func focusedParentPath(_ workspace: Workspace) -> DwindlePath? {
    guard let focused = workspace.focusedWindow, let path = workspace.dwindle.root?.path(to: focused),
          !path.isEmpty
    else {
        return nil
    }
    return Array(path.dropLast())
}

/// The split at `path` rewritten by `change`; unchanged when nothing changed.
private func rewritingSplit(
    at path: DwindlePath, in workspace: Workspace, _ change: (inout DwindleSplit) -> Void
) -> Workspace {
    guard let root = workspace.dwindle.root, case .split(var split)? = root.node(at: path) else {
        return workspace
    }
    let before = split
    change(&split)
    guard split != before else {
        return workspace
    }
    var next = workspace
    next.dwindle.root = root.replacing(at: path, with: .split(split))
    return next
}

// MARK: - Focus and move

/// DW-02: focus-left/right/up/down in dwindle: the geometric neighbour.
/// Unchanged at the edge, without focus, or for a scrolling workspace.
public func dwindleFocus(in workspace: Workspace, direction: FocusDirection, geometry: DwindleGeometry) -> Workspace {
    guard workspace.layout == .dwindle, let focused = workspace.focusedWindow,
          let layout = dwindleActionLayout(workspace, geometry: geometry),
          let target = dwindleNeighbour(
              of: focused, direction: direction, frames: layout.frames, order: workspace.dwindle.windows
          )
    else {
        return workspace
    }
    return focusing(target, in: workspace)
}

/// DW-02: move-left/right/up/down (and move-column-*, swap-window-*) in
/// dwindle: the focused window trades tiles with its geometric neighbour
/// and keeps the focus. `.atEdge` when no tile is that way.
public func dwindleMove(in workspace: Workspace, direction: FocusDirection, geometry: DwindleGeometry) -> DwindleStep {
    guard workspace.layout == .dwindle, let focused = workspace.focusedWindow,
          let root = workspace.dwindle.root, root.path(to: focused) != nil,
          let layout = dwindleActionLayout(workspace, geometry: geometry)
    else {
        return .unchanged
    }
    guard let target = dwindleNeighbour(
        of: focused, direction: direction, frames: layout.frames, order: workspace.dwindle.windows
    ) else {
        return .atEdge
    }
    var next = workspace
    next.dwindle.root = root.swappingLeaves(focused, target)
    next.reconcileDwindle(splitRatio: geometry.config.dwindle.splitRatio)
    return .moved(next)
}

/// DW-02 focus-column-first / -last in dwindle: the first or last window
/// in leaf order (top-left and the innermost tile of a spiral).
public func dwindleFocusEnd(in workspace: Workspace, last: Bool) -> Workspace {
    let order = workspace.dwindle.windows
    guard workspace.layout == .dwindle, let target = last ? order.last : order.first,
          target != workspace.focusedWindow
    else {
        return workspace
    }
    return focusing(target, in: workspace)
}

// MARK: - Split commands

/// DW-02 `dwindle-toggle-split`: the split holding the focused window
/// flips between side by side and stacked (from the way it is laid out
/// now) and keeps that orientation; the splits inside it keep theirs.
public func dwindleToggleSplit(in workspace: Workspace, geometry: DwindleGeometry) -> Workspace {
    guard workspace.layout == .dwindle, let path = focusedParentPath(workspace),
          let layout = dwindleActionLayout(workspace, geometry: geometry)
    else {
        return workspace
    }
    return rewritingSplit(at: path, in: pinned(workspace, layout)) { split in
        split.orientation = (layout.splits[path]?.orientation ?? split.orientation ?? .horizontal).flipped
    }
}

/// DW-02 `dwindle-swap-split`: the two halves of the split holding the
/// focused window trade places, each keeping its size.
public func dwindleSwapSplit(in workspace: Workspace) -> Workspace {
    guard workspace.layout == .dwindle, let path = focusedParentPath(workspace) else {
        return workspace
    }
    var next = rewritingSplit(at: path, in: workspace) { split in
        (split.first, split.second) = (split.second, split.first)
        split.ratio = clampedDwindleRatio(2 - split.ratio)
    }
    next.reconcileDwindle(splitRatio: 1)
    return next
}

/// DW-02 `dwindle-balance`: every split of the workspace back to half and half.
public func dwindleBalance(in workspace: Workspace) -> Workspace {
    guard workspace.layout == .dwindle, let root = workspace.dwindle.root else {
        return workspace
    }
    let balanced = root.mappingSplits { split in
        var even = split
        even.ratio = 1
        return even
    }
    guard balanced != root else {
        return workspace
    }
    var next = workspace
    next.dwindle.root = balanced
    return next
}

/// DW-02 `dwindle-preselect-*` / `dwindle-preselect-clear` (nil): where
/// the next window of this workspace opens.
public func dwindlePreselect(in workspace: Workspace, direction: FocusDirection?) -> Workspace {
    guard workspace.layout == .dwindle, workspace.dwindle.preselection != direction else {
        return workspace
    }
    var next = workspace
    next.dwindle.preselection = direction
    return next
}

/// DW-02 `maximize-column` in dwindle: the focused window fills the area
/// inside the padding (again to restore; it ends when it loses focus).
public func dwindleToggleMaximize(in workspace: Workspace) -> Workspace {
    guard workspace.layout == .dwindle, let focused = workspace.focusedWindow else {
        return workspace
    }
    var next = workspace
    next.dwindle.maximized = workspace.dwindle.maximized == focused ? nil : focused
    return next
}

// MARK: - Sizes

/// `workspace` with every split `layout` laid out pinned to that shape, so
/// a ratio change never flips a split that was still following its shape.
private func pinned(_ workspace: Workspace, _ layout: DwindleLayout) -> Workspace {
    var next = workspace
    next.dwindle.root = workspace.dwindle.root?.pinningOrientations(layout.orientations)
    return next
}

/// The nearest split above the focused window laid out along `axis`, the
/// side the focused window is on, that split's laid-out placement, and
/// the workspace with its laid-out splits pinned (the base to rewrite).
private func nearestSplit(
    _ workspace: Workspace, axis: DwindleOrientation, geometry: DwindleGeometry
) -> (base: Workspace, path: DwindlePath, side: DwindleSide, placement: DwindleSplitPlacement)? {
    guard workspace.layout == .dwindle, let focused = workspace.focusedWindow,
          let leaf = workspace.dwindle.root?.path(to: focused),
          let layout = dwindleActionLayout(workspace, geometry: geometry)
    else {
        return nil
    }
    for depth in stride(from: leaf.count - 1, through: 0, by: -1) {
        let path = Array(leaf.prefix(depth))
        if let placement = layout.splits[path], placement.orientation == axis {
            return (pinned(workspace, layout), path, leaf[depth], placement)
        }
    }
    return nil
}

/// The split at `found.path` rewritten on the pinned base; the original
/// workspace when the split did not change (a no-op stays a no-op).
private func rewritingNearest(
    _ found: (base: Workspace, path: DwindlePath, side: DwindleSide, placement: DwindleSplitPlacement),
    original: Workspace, _ change: (inout DwindleSplit) -> Void
) -> Workspace {
    let next = rewritingSplit(at: found.path, in: found.base, change)
    return next == found.base ? original : next
}

/// The focused side's share (0...1) of a split, as a ratio.
private func ratio(forShare share: CGFloat, side: DwindleSide) -> CGFloat {
    clampedDwindleRatio((side == .first ? share : 1 - share) * 2)
}

/// DW-02 width / height steps in dwindle (`set-column-width-plus/minus`
/// on the horizontal axis, `set-window-height-plus/minus` on the vertical
/// one): the nearest split along `axis` gives the focused window's side
/// `delta` more (or less) of its extent. Unchanged without such a split
/// or at the 0.1 / 1.9 ratio limits.
public func dwindleResize(
    in workspace: Workspace, axis: DwindleOrientation, by delta: CGFloat, geometry: DwindleGeometry
) -> Workspace {
    guard let found = nearestSplit(workspace, axis: axis, geometry: geometry) else {
        return workspace
    }
    return rewritingNearest(found, original: workspace) { split in
        let share = (found.side == .first ? split.ratio : 2 - split.ratio) / 2
        split.ratio = ratio(forShare: share + delta, side: found.side)
    }
}

/// DW-02 preset cycles in dwindle (`switch-preset-column-width[-back]` on
/// the horizontal axis with `preset-column-widths`,
/// `switch-preset-window-height` on the vertical one with
/// `preset-window-heights`): the focused window's share of the nearest
/// split along `axis` goes to the next preset (a fraction is a share of
/// the split, points are measured against it), wrapping around.
public func dwindleSwitchPreset(
    in workspace: Workspace, axis: DwindleOrientation, presets: [ColumnWidthSpec], forward: Bool,
    geometry: DwindleGeometry
) -> Workspace {
    guard !presets.isEmpty, let found = nearestSplit(workspace, axis: axis, geometry: geometry) else {
        return workspace
    }
    let extent = (axis == .horizontal ? found.placement.rect.width : found.placement.rect.height) - geometry.config.gap
    guard extent > 0 else {
        return workspace
    }
    let shares: [CGFloat] = presets.map { spec in
        switch spec {
        case .proportion(let value): return value
        case .points(let value): return value / extent
        case .standard: return 0.5
        }
    }.map { min(max($0, 0.05), 0.95) }
    return rewritingNearest(found, original: workspace) { split in
        let current = (found.side == .first ? split.ratio : 2 - split.ratio) / 2
        let epsilon: CGFloat = 0.005
        let chosen = forward
            ? shares.first { $0 > current + epsilon } ?? shares[0]
            : shares.last { $0 < current - epsilon } ?? shares[shares.count - 1]
        split.ratio = ratio(forShare: chosen, side: found.side)
    }
}

/// DW-02 `reset-window-height` in dwindle: the nearest stacked split above
/// the focused window back to half and half.
public func dwindleResetSplit(in workspace: Workspace, axis: DwindleOrientation, geometry: DwindleGeometry) -> Workspace {
    guard let found = nearestSplit(workspace, axis: axis, geometry: geometry) else {
        return workspace
    }
    return rewritingNearest(found, original: workspace) { $0.ratio = 1 }
}

// MARK: - Layout-aware steps (scrolling or dwindle)

/// DW-02: the in-workspace part of a directional focus for either layout:
/// `moveFocus` on the strip, `dwindleFocus` on the tree.
public func focusNeighbour(
    in workspace: Workspace, direction: FocusDirection, geometry: @autoclosure () -> DwindleGeometry
) -> Workspace {
    workspace.layout == .dwindle
        ? dwindleFocus(in: workspace, direction: direction, geometry: geometry())
        : moveFocus(in: workspace, direction: direction)
}
