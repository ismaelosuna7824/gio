import CoreGraphics
import Foundation

/// One display's layout for one reflow: the workspace with its (possibly
/// revealed) viewport offset, and the visible/parked split ready for the
/// reconciler.
public struct DisplayLayoutPlan: Equatable, Sendable {
    public var workspace: Workspace
    public var layout: LayoutResult
    public var plan: ParkingPlan
}

/// Pure pipeline of one display's reflow: lay the strip out, reveal the
/// focused column (Niri rule: it is always visible) by scrolling minimally,
/// lay out again from the scrolled offset, then park off-viewport columns.
/// Same inputs always give the same plan, so a rescan that changes nothing
/// yields frames the windows already have.
public func planDisplayLayout(
    workspace: Workspace,
    modes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine,
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect]
) throws -> DisplayLayoutPlan {
    var workspace = workspace
    var layout = try engine.calculate(
        workspace: tilingWorkspace(from: workspace, modes: modes), viewport: viewport
    )
    if let revealed = revealOffset(workspace: workspace, layout: layout, viewport: viewport),
       revealed != workspace.viewportOffset
    {
        var scrolled = workspace
        scrolled.viewportOffset = revealed
        if let relaid = try? engine.calculate(
            workspace: tilingWorkspace(from: scrolled, modes: modes), viewport: viewport
        ) {
            layout = relaid
            workspace.viewportOffset = revealed
        }
    }
    let plan = planParking(
        frames: layout.frames, viewport: viewport, display: display, otherDisplays: otherDisplays
    )
    workspace.viewportOffset = layout.viewportOffset
    return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: plan)
}

/// Focused column's content range revealed into the viewport. Nil when
/// nothing needs scrolling (or no focused window to reveal).
public func revealOffset(
    workspace: Workspace, layout: LayoutResult, viewport: CGRect
) -> CGFloat? {
    guard let focused = workspace.focusedWindow,
          let column = workspace.columns.first(where: { $0.windows.contains(focused) })
    else {
        return nil
    }
    let frames = column.windows.compactMap { layout.frames[$0] }
    guard !frames.isEmpty else {
        return nil
    }
    let lower = frames.map(\.origin.x).min()!
    let upper = frames.map(\.maxX).max()!
    let revealed = Viewport(offset: workspace.viewportOffset, width: viewport.width)
        .ensureVisible(range: lower..<upper, contentWidth: layout.contentWidth)
    return revealed.offset == workspace.viewportOffset ? nil : revealed.offset
}
