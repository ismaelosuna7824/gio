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
/// yields frames the windows already have. DW-01: a dwindle workspace goes
/// through `planDwindleDisplayLayout` instead (no scrolling, no parking).
public func planDisplayLayout(
    workspace: Workspace,
    modes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine,
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect],
    centering: CenterRequest = .none
) throws -> DisplayLayoutPlan {
    if workspace.layout == .dwindle {
        return try planDwindleDisplayLayout(
            workspace: workspace, modes: modes, config: engine.config,
            viewport: viewport, display: display, otherDisplays: otherDisplays
        )
    }
    var workspace = workspace
    let covering = fullscreenWindow(in: workspace, modes: modes)
    let layoutModes = covering == nil ? modesKeepingFullscreenInColumns(modes) : modes
    var layout = try covering == nil
        ? layoutKeepingFullscreenSize(
            workspace: workspace, modes: modes, layoutModes: layoutModes, engine: engine,
            viewport: viewport, display: display
        )
        : engine.calculate(workspace: tilingWorkspace(from: workspace, modes: layoutModes), viewport: viewport)
    if let covering {
        // Real fullscreen: the window fills the display and every tiled
        // window parks where its column already is, so leaving fullscreen
        // finds the strip exactly as it was.
        var plan = ParkingPlan(
            visible: [covering: fullscreenFrame(display: display, usable: viewport, gap: engine.config.fullscreenGap)],
            parked: parkAll(
                frames: layout.frames, viewport: viewport, display: display,
                otherDisplays: otherDisplays
            )
        )
        plan.parked.removeValue(forKey: covering)
        workspace.viewportOffset = layout.viewportOffset
        return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: plan)
    }
    if let revealed = revealOffset(
        workspace: workspace, layout: layout, viewport: viewport, edgeMargin: engine.config.padding,
        centering: centering
    ),
       revealed != workspace.viewportOffset
    {
        var scrolled = workspace
        scrolled.viewportOffset = revealed
        if let relaid = try? layoutKeepingFullscreenSize(
            workspace: scrolled, modes: modes, layoutModes: layoutModes, engine: engine,
            viewport: viewport, display: display
        ) {
            layout = relaid
            workspace.viewportOffset = revealed
        }
    }
    // MM-08: a column across an edge another display shares is parked off
    // the display (MM-04), which leaves its part of this display empty. When
    // the focused column can sit flush against that edge instead, the cut
    // moves to a free edge, where a column peeks as on a single display.
    // Centering (this pass's request or the configured mode) keeps its offset.
    if engine.config.centerFocusedColumn == .never, centering.mode == .never,
       let shifted = straddleFreeOffset(
           workspace: workspace, layout: layout, viewport: viewport, edgeMargin: engine.config.padding,
           otherDisplays: otherDisplays
       ),
       let relaid = try? layoutKeepingFullscreenSize(
           workspace: { var scrolled = workspace; scrolled.viewportOffset = shifted; return scrolled }(),
           modes: modes, layoutModes: layoutModes, engine: engine, viewport: viewport, display: display
       )
    {
        layout = relaid
        workspace.viewportOffset = relaid.viewportOffset
    }
    let focusedColumn = workspace.focusedWindow.flatMap { focused in
        workspace.columns.first { $0.windows.contains(focused) }
    }
    let plan = planParking(
        frames: layout.frames, viewport: viewport, display: display, otherDisplays: otherDisplays,
        focusedColumn: Set(focusedColumn?.windows ?? [])
    )
    workspace.viewportOffset = layout.viewportOffset
    return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: plan)
}

/// The window covering the display, when the focused workspace member is
/// fullscreen (or none is focused: the first fullscreen in column order).
func fullscreenWindow(in workspace: Workspace, modes: [WindowID: WindowMode]) -> WindowID? {
    guard let focused = workspace.focusedWindow else {
        return workspace.columns.flatMap(\.windows).first { modes[$0] == .fullscreen }
    }
    return modes[focused] == .fullscreen ? focused : nil
}

private func layoutKeepingFullscreenSize(
    workspace: Workspace, modes: [WindowID: WindowMode], layoutModes: [WindowID: WindowMode],
    engine: ScrollableLayoutEngine, viewport: CGRect, display: CGRect
) throws -> LayoutResult {
    let frame = fullscreenFrame(display: display, usable: viewport, gap: engine.config.fullscreenGap)
    var widened = workspace
    widened.columns = workspace.columns.map { column in
        var widened = column
        if column.windows.contains(where: { modes[$0] == .fullscreen }) {
            widened.widthSpec = .points(frame.width)
        }
        return widened
    }
    let layout = try engine.calculate(
        workspace: tilingWorkspace(from: widened, modes: layoutModes), viewport: viewport
    )
    var frames = layout.frames
    for (window, placed) in layout.frames where modes[window] == .fullscreen {
        frames[window] = CGRect(x: placed.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
    return LayoutResult(frames: frames, contentWidth: layout.contentWidth, viewportOffset: layout.viewportOffset)
}

private func modesKeepingFullscreenInColumns(_ modes: [WindowID: WindowMode]) -> [WindowID: WindowMode] {
    modes.mapValues { $0 == .fullscreen ? .tiled : $0 }
}

/// DW-04: a workspace's frames for read-only views (the overview strip):
/// the strip engine for a scrolling workspace, the dwindle tiles (offset 0,
/// the viewport as the content width) for a dwindle one. No reveal, no
/// parking: callers only measure.
public func workspaceLayoutResult(
    _ workspace: Workspace, modes: [WindowID: WindowMode], engine: ScrollableLayoutEngine, viewport: CGRect
) throws -> LayoutResult {
    guard workspace.layout == .dwindle else {
        return try engine.calculate(workspace: tilingWorkspace(from: workspace, modes: modes), viewport: viewport)
    }
    var reconciled = workspace
    reconciled.reconcileDwindle(splitRatio: engine.config.dwindle.splitRatio)
    let frames = try DwindleLayoutEngine(config: engine.config).layout(
        reconciled.dwindle, viewport: viewport, modes: modesKeepingFullscreenInColumns(modes)
    ).frames
    return LayoutResult(frames: frames, contentWidth: viewport.width, viewportOffset: 0)
}

/// DW-01: one display's dwindle pass. Every tiled window sits in its tile
/// (nothing scrolls, nothing parks; the viewport offset stays 0). The
/// workspace is reconciled first, so a window the tree misses still gets a
/// tile, and the returned workspace has every split this pass laid out
/// pinned to the orientation it got (a new split takes its shape from the
/// first display that shows it and keeps it; the host stores it back like
/// the viewport offset). A focused fullscreen window covers the display and
/// the others park where their tiles are (as in scrolling); an unfocused
/// fullscreen window keeps its tile. A maximized focused window fills the
/// area inside the padding, the others staying in their tiles behind it.
func planDwindleDisplayLayout(
    workspace: Workspace, modes: [WindowID: WindowMode], config: LayoutConfig,
    viewport: CGRect, display: CGRect, otherDisplays: [CGRect]
) throws -> DisplayLayoutPlan {
    var workspace = workspace
    workspace.reconcileDwindle(splitRatio: config.dwindle.splitRatio)
    workspace.viewportOffset = 0
    let covering = fullscreenWindow(in: workspace, modes: modes)
    let laid = try DwindleLayoutEngine(config: config).layout(
        workspace.dwindle, viewport: viewport, modes: modesKeepingFullscreenInColumns(modes)
    )
    workspace.dwindle.root = workspace.dwindle.root?.pinningOrientations(laid.orientations)
    var frames = laid.frames
    let layout = LayoutResult(frames: frames, contentWidth: viewport.width, viewportOffset: 0)
    if let covering {
        var parked = parkAll(frames: frames, viewport: viewport, display: display, otherDisplays: otherDisplays)
        parked.removeValue(forKey: covering)
        let plan = ParkingPlan(
            visible: [covering: fullscreenFrame(display: display, usable: viewport, gap: config.fullscreenGap)],
            parked: parked
        )
        return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: plan)
    }
    if let maximized = workspace.dwindle.maximized, frames[maximized] != nil {
        frames[maximized] = viewport.insetBy(dx: config.padding, dy: config.padding)
    }
    return DisplayLayoutPlan(workspace: workspace, layout: layout, plan: ParkingPlan(visible: frames, parked: [:]))
}

/// Focused column's content range revealed into the viewport. Nil when
/// nothing needs scrolling (or no focused window to reveal). A minimal
/// scroll stops `edgeMargin` (the strip padding) short of the screen edge,
/// like the strip's own ends, unless the column is too wide for it. `centering`
/// (keyboard focus changes only) swaps the minimal scroll for a centered one
/// when the mode asks for it (Niri `center-focused-column`).
public func revealOffset(
    workspace: Workspace, layout: LayoutResult, viewport: CGRect, edgeMargin: CGFloat,
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
        let padded = (range.lowerBound - edgeMargin)..<(range.upperBound + edgeMargin)
        let reveal = padded.upperBound - padded.lowerBound <= viewport.width ? padded : range
        target = Viewport(offset: layout.viewportOffset, width: viewport.width)
            .ensureVisible(range: reveal, contentWidth: layout.contentWidth).offset
    }
    return target == layout.viewportOffset ? nil : target
}

/// MM-08: a viewport offset that keeps the focused column fully visible and
/// leaves fewer columns across an edge `viewport` shares with another
/// display than `layout`'s own offset does (those columns park, leaving their
/// part of the display empty). Candidates: the focused column flush with
/// either side (inside `edgeMargin`, clamped to the strip); the fewest
/// stranded columns wins, then the smallest scroll. Nil when nothing is
/// stranded or no candidate does better.
public func straddleFreeOffset(
    workspace: Workspace, layout: LayoutResult, viewport: CGRect, edgeMargin: CGFloat,
    otherDisplays: [CGRect]
) -> CGFloat? {
    guard !otherDisplays.isEmpty,
          let focused = workspace.focusedWindow,
          let column = workspace.columns.first(where: { $0.windows.contains(focused) })
    else {
        return nil
    }
    let current = layout.viewportOffset
    let toContent = current - viewport.minX
    guard let range = contentRange(of: column, in: layout, toContent: toContent) else {
        return nil
    }
    let others = workspace.columns.filter { $0.id != column.id }.map { other in
        other.windows.compactMap { layout.frames[$0] }
    }
    func stranded(at offset: CGFloat) -> Int {
        let dx = current - offset
        return others.filter { frames in
            frames.contains { frame in
                let moved = frame.offsetBy(dx: dx, dy: 0)
                return moved.intersects(viewport) && otherDisplays.contains { $0.intersects(moved) }
            }
        }.count
    }
    let now = stranded(at: current)
    guard now > 0 else {
        return nil
    }
    let maxOffset = max(0, layout.contentWidth - viewport.width)
    let fits = range.upperBound - range.lowerBound + 2 * edgeMargin <= viewport.width
    let raw = fits
        ? [range.lowerBound - edgeMargin, range.upperBound + edgeMargin - viewport.width]
        : [range.lowerBound]
    let shown: (CGFloat) -> Bool = { offset in
        range.upperBound - range.lowerBound > viewport.width
            || (range.lowerBound >= offset && range.upperBound <= offset + viewport.width)
    }
    let best = raw.map { min(max($0, 0), maxOffset) }
        .filter { $0 != current && shown($0) }
        .map { (offset: $0, stranded: stranded(at: $0)) }
        .min { ($0.stranded, abs($0.offset - current)) < ($1.stranded, abs($1.offset - current)) }
    guard let best, best.stranded < now else {
        return nil
    }
    return best.offset
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
