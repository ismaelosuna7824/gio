import CoreGraphics
import Foundation

/// Niri `center-column`: scroll the strip so the focused window's column sits
/// in the middle of the viewport, clamped to the content bounds (the first and
/// last columns cannot be centered past the strip edge). Only the offset
/// changes; the next reflow's reveal rule keeps it because a centered column
/// is already fully visible.
///
/// NO-OP (workspace returned unchanged) without a focused tiled window or
/// when the layout cannot be computed.
public func centerFocusedColumn(
    in workspace: Workspace,
    modes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine,
    viewport: CGRect
) -> Workspace {
    guard let focused = workspace.focusedWindow else {
        return workspace
    }
    // Measure the strip at offset zero so frames read as content coordinates.
    var probe = tilingWorkspace(from: workspace, modes: modes)
    probe.viewportOffset = 0
    guard let column = probe.columns.first(where: { $0.windows.contains(focused) }),
          let layout = try? engine.calculate(workspace: probe, viewport: viewport)
    else {
        return workspace
    }
    let frames = column.windows.compactMap { layout.frames[$0] }
    guard let lower = frames.map(\.minX).min(), let upper = frames.map(\.maxX).max() else {
        return workspace
    }
    let center = (lower + upper) / 2 - viewport.minX
    let maxOffset = max(0, layout.contentWidth - viewport.width)
    var next = workspace
    next.viewportOffset = min(max(center - viewport.width / 2, 0), maxOffset)
    return next
}
