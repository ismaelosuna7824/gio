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
    otherDisplays: [CGRect],
    centering: CenterRequest = .none
) throws -> DisplayLayoutPlan {
    var workspace = workspace
    var layout = try engine.calculate(
        workspace: tilingWorkspace(from: workspace, modes: modes), viewport: viewport
    )
    if let covering = fullscreenWindow(in: workspace, modes: modes) {
        // Real fullscreen: the window fills the display and every tiled
        // window parks where its column already is, so leaving fullscreen
        // finds the strip exactly as it was.
        var plan = ParkingPlan(
            visible: [covering: fullscreenFrame(display: display, usable: viewport)],
            parked: parkAll(
                frames: layout.frames, viewport: viewport, display: display,
                otherDisplays: otherDisplays
            )
        )
        plan.parked.removeValue(forKey: covering)
        workspace.viewportOffset = layout.viewportOffset
        return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: plan)
    }
    if let revealed = revealOffset(workspace: workspace, layout: layout, viewport: viewport, centering: centering),
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

/// The window covering the display, when any workspace member is fullscreen:
/// the focused one if it is, else the first in column order.
func fullscreenWindow(in workspace: Workspace, modes: [WindowID: WindowMode]) -> WindowID? {
    if let focused = workspace.focusedWindow, modes[focused] == .fullscreen {
        return focused
    }
    return workspace.columns.flatMap(\.windows).first { modes[$0] == .fullscreen }
}

/// Focused column's content range revealed into the viewport. Nil when
/// nothing needs scrolling (or no focused window to reveal). `centering`
/// (keyboard focus changes only) swaps the minimal scroll for a centered one
/// when the mode asks for it (Niri `center-focused-column`).
public func revealOffset(
    workspace: Workspace, layout: LayoutResult, viewport: CGRect,
    centering: CenterRequest = .none
) -> CGFloat? {
    guard let focused = workspace.focusedWindow,
          let column = workspace.columns.first(where: { $0.windows.contains(focused) })
    else {
        return nil
    }
    // Layout frames are screen rects (`viewport.minX + contentX - offset`);
    // the viewport scrolls in content space, so convert back before comparing.
    let toContent = layout.viewportOffset - viewport.minX
    guard let range = contentRange(of: column, in: layout, toContent: toContent) else {
        return nil
    }
    let target: CGFloat
    if shouldCenter(centering, focused: column, range: range, workspace: workspace, layout: layout,
                    viewportWidth: viewport.width, toContent: toContent)
    {
        let maxOffset = max(0, layout.contentWidth - viewport.width)
        target = min(max((range.lowerBound + range.upperBound) / 2 - viewport.width / 2, 0), maxOffset)
    } else {
        target = Viewport(offset: layout.viewportOffset, width: viewport.width)
            .ensureVisible(range: range, contentWidth: layout.contentWidth).offset
    }
    return target == layout.viewportOffset ? nil : target
}

private func contentRange(of column: Column, in layout: LayoutResult, toContent: CGFloat) -> Range<CGFloat>? {
    let frames = column.windows.compactMap { layout.frames[$0] }
    guard let lower = frames.map(\.origin.x).min(), let upper = frames.map(\.maxX).max() else {
        return nil
    }
    return (lower + toContent)..<(upper + toContent)
}

private func shouldCenter(
    _ request: CenterRequest, focused: Column, range: Range<CGFloat>, workspace: Workspace,
    layout: LayoutResult, viewportWidth: CGFloat, toContent: CGFloat
) -> Bool {
    switch request.mode {
    case .never:
        return false
    case .always:
        return true
    case .onOverflow:
        guard let previous = request.previouslyFocused,
              let previousColumn = workspace.columns.first(where: { $0.windows.contains(previous) }),
              previousColumn.id != focused.id,
              let previousRange = contentRange(of: previousColumn, in: layout, toContent: toContent)
        else {
            return false
        }
        let span = max(range.upperBound, previousRange.upperBound) - min(range.lowerBound, previousRange.lowerBound)
        return span > viewportWidth
    }
}
