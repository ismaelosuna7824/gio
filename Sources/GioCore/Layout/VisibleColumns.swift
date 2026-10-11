import CoreGraphics
import Foundation

/// The tiled strip as it is on screen now: each column's content range,
/// which of them are fully visible, and where the focused one is. Content
/// x = screen x - `viewport.minX` + offset (layout frames are screen rects).
private struct VisibleStrip {
    var ranges: [ClosedRange<CGFloat>]
    var focused: Int
    var offset: CGFloat
    var contentWidth: CGFloat
    var fullyVisible: [Int]
}

/// Tolerance for "fully visible" and for "nothing changed" (points).
private let visibleEpsilon: CGFloat = 0.5

private func measureVisibleStrip(
    _ workspace: Workspace, modes: [WindowID: WindowMode], engine: ScrollableLayoutEngine, viewport: CGRect
) -> VisibleStrip? {
    guard let focusedWindow = workspace.focusedWindow else {
        return nil
    }
    let tiled = tilingWorkspace(from: workspace, modes: modes)
    guard let focused = tiled.columns.firstIndex(where: { $0.windows.contains(focusedWindow) }),
          let layout = try? engine.calculate(workspace: tiled, viewport: viewport)
    else {
        return nil
    }
    let toContent = layout.viewportOffset - viewport.minX
    var ranges: [ClosedRange<CGFloat>] = []
    for column in tiled.columns {
        let frames = column.windows.compactMap { layout.frames[$0] }
        guard let lower = frames.map(\.minX).min(), let upper = frames.map(\.maxX).max() else {
            return nil
        }
        ranges.append((lower + toContent)...(upper + toContent))
    }
    let offset = layout.viewportOffset
    let fullyVisible = ranges.indices.filter {
        ranges[$0].lowerBound >= offset - visibleEpsilon
            && ranges[$0].upperBound <= offset + viewport.width + visibleEpsilon
    }
    return VisibleStrip(
        ranges: ranges, focused: focused, offset: offset, contentWidth: layout.contentWidth,
        fullyVisible: fullyVisible
    )
}

/// Niri `expand-column-to-available-width`: the focused column takes the
/// width the other fully visible columns leave in the viewport (minus the
/// padding and the gaps), and the view scrolls so that group fills it from
/// padding to padding. The width is stored as a proportion, like the other
/// width actions, so it adapts across displays.
///
/// NO-OP (workspace returned unchanged) without a focused tiled window, when
/// the layout cannot be computed, or when there is no room to grow into.
public func expandColumnToAvailableWidth(
    in workspace: Workspace,
    modes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine,
    viewport: CGRect
) -> Workspace {
    guard let strip = measureVisibleStrip(workspace, modes: modes, engine: engine, viewport: viewport),
          workspace.focusedColumn >= 0, workspace.focusedColumn < workspace.columns.count
    else {
        return workspace
    }
    let config = engine.config
    let others = strip.fullyVisible.filter { $0 != strip.focused }
    let taken = others.reduce(0) { $0 + strip.ranges[$1].upperBound - strip.ranges[$1].lowerBound }
        + config.gap * CGFloat(others.count)
    let available = viewport.width - config.padding * 2 - taken
    let current = strip.ranges[strip.focused].upperBound - strip.ranges[strip.focused].lowerBound
    let proportionBase = viewport.width - config.padding * 2 + config.gap
    guard available > current + visibleEpsilon, proportionBase > 0 else {
        return workspace
    }
    var next = workspace
    next.columns[workspace.focusedColumn].widthSpec = .proportion(min((available + config.gap) / proportionBase, 1))
    let groupStart = ([strip.focused] + others).map { strip.ranges[$0].lowerBound }.min() ?? 0
    next.viewportOffset = max(groupStart - config.padding, 0)
    return next
}

/// Niri `center-visible-columns`: scroll so the fully visible columns (and
/// the focused one) sit in the middle of the viewport, clamped to the strip.
/// Only the offset changes; the next reflow keeps it because the focused
/// column stays fully visible.
///
/// NO-OP (workspace returned unchanged) without a focused tiled window, when
/// the layout cannot be computed, or when the group is already centered (or
/// cannot move past a strip edge).
public func centerVisibleColumns(
    in workspace: Workspace,
    modes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine,
    viewport: CGRect
) -> Workspace {
    guard let strip = measureVisibleStrip(workspace, modes: modes, engine: engine, viewport: viewport) else {
        return workspace
    }
    let group = Set(strip.fullyVisible).union([strip.focused])
    let lower = group.map { strip.ranges[$0].lowerBound }.min() ?? 0
    let upper = group.map { strip.ranges[$0].upperBound }.max() ?? 0
    let maxOffset = max(0, strip.contentWidth - viewport.width)
    let target = min(max((lower + upper) / 2 - viewport.width / 2, 0), maxOffset)
    guard abs(target - strip.offset) > visibleEpsilon else {
        return workspace
    }
    var next = workspace
    next.viewportOffset = target
    return next
}
