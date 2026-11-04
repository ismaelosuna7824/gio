import CoreGraphics
import Foundation

/// MD-01: a mouse button as the event tap sees it.
public enum MouseButton: String, Equatable, Sendable {
    case left
    case right
    case other
}

public enum MouseButtonPhase: String, Equatable, Sendable {
    case down
    case dragged
    case up
}

/// MD-01: one mouse button event from the tap (Cocoa location) with the
/// modifiers held.
public struct MouseButtonEvent: Equatable, Sendable {
    public var phase: MouseButtonPhase
    public var button: MouseButton
    public var location: CGPoint
    public var modifiers: Set<HotkeyModifier>

    public init(phase: MouseButtonPhase, button: MouseButton, location: CGPoint, modifiers: Set<HotkeyModifier>) {
        self.phase = phase
        self.button = button
        self.location = location
        self.modifiers = modifiers
    }
}

/// MD-01: what a modifier drag on a tiled window does.
public enum MouseDragKind: String, Equatable, Sendable {
    /// Left button: the window follows the pointer and drops into a slot.
    case move
    /// Right button: the window's column width and its height in the column.
    case resize
}

/// MD-01 `[behavior] mouse-move-window`, `mouse-resize-window` and
/// `mouse-drag-modifiers`.
public struct MouseDragSettings: Equatable, Sendable {
    public var move: Bool
    public var resize: Bool
    public var modifiers: Set<HotkeyModifier>

    public init(move: Bool = true, resize: Bool = true, modifiers: Set<HotkeyModifier> = [.alt]) {
        self.move = move
        self.resize = resize
        self.modifiers = modifiers
    }
}

/// The drag a button press starts: exactly the configured modifiers, left
/// moves and right resizes. No modifier never starts one (every click would
/// be taken from the apps).
public func mouseDragKind(for event: MouseButtonEvent, settings: MouseDragSettings) -> MouseDragKind? {
    guard event.phase == .down, !settings.modifiers.isEmpty, event.modifiers == settings.modifiers else {
        return nil
    }
    switch event.button {
    case .left: return settings.move ? .move : nil
    case .right: return settings.resize ? .resize : nil
    case .other: return nil
    }
}

// MARK: - Resize

/// MD-01: a resize in progress. The edges nearest the grab point move: the
/// left or right edge by the horizontal travel, the top or bottom edge by
/// the vertical travel (only in a stacked column).
public struct MouseResize: Equatable, Sendable {
    public let window: WindowID
    /// The workspace the drag started from, with the widths it showed.
    public let start: Workspace
    public let origin: CGPoint
    public let startWidth: CGFloat
    public let startHeight: CGFloat
    public let growsLeft: Bool
    public let growsUp: Bool
}

/// A resize of `window` grabbed at `point`; nil off a scrolling strip, for
/// a window that is not tiled on it, or with a fullscreen window shown.
/// The start keeps what the user sees: widths `fill-empty-space` stretched
/// become the columns' widths, so nothing jumps when the drag pauses the
/// filling.
public func beginMouseResize(_ surface: GestureSurface, window: WindowID, at point: CGPoint) -> MouseResize? {
    guard gestureStrip(surface) != nil, (surface.modes[window] ?? .tiled) == .tiled,
          surface.workspace.columns.contains(where: { $0.windows.contains(window) })
    else {
        return nil
    }
    let tiled = tilingWorkspace(from: surface.workspace, modes: surface.modes)
    guard let layout = try? surface.engine.calculate(workspace: tiled, viewport: surface.viewport),
          let frame = layout.frames[window]
    else {
        return nil
    }
    var start = surface.workspace
    let config = surface.engine.config
    if tiled.filledColumnCount >= 2 {
        for index in start.columns.indices {
            guard let shown = start.columns[index].windows.lazy.compactMap({ layout.frames[$0] }).first else {
                continue
            }
            let stored = config.resolvedWidth(of: start.columns[index].widthSpec, viewportWidth: surface.viewport.width)
            if abs(shown.width - stored) > 1 {
                start.columns[index].widthSpec = mouseWidthSpec(shown.width, config: config, viewport: surface.viewport)
            }
        }
    }
    start.noteColumnsResized()
    return MouseResize(
        window: window, start: start, origin: point, startWidth: frame.width, startHeight: frame.height,
        growsLeft: point.x < frame.midX, growsUp: point.y > frame.midY
    )
}

/// The workspace with the resize's window at the size the pointer at
/// `point` asks for. Widths are proportions of the strip (as the width
/// actions set them), clamped between the minimum column width and the
/// strip; a left-edge grab moves the view so the right edge stays put.
public func mouseResized(_ resize: MouseResize, surface: GestureSurface, to point: CGPoint) -> Workspace {
    let config = surface.engine.config
    var next = resize.start
    guard let column = next.columns.firstIndex(where: { $0.windows.contains(resize.window) }) else {
        return next
    }
    let dx = point.x - resize.origin.x
    let dy = point.y - resize.origin.y
    let usable = surface.viewport.width - config.padding * 2
    let width = min(max(resize.startWidth + (resize.growsLeft ? -dx : dx), min(config.minimumColumnWidth, usable)), usable)
    next.columns[column].widthSpec = mouseWidthSpec(width, config: config, viewport: surface.viewport)
    if resize.growsLeft {
        next.viewportOffset = max(resize.start.viewportOffset + (width - resize.startWidth), 0)
    }
    let height = resize.startHeight + (resize.growsUp ? dy : -dy)
    next = settingWindowHeight(
        resize.window, to: height, in: next, config: config, viewportHeight: surface.viewport.height
    )
    return next
}

private func mouseWidthSpec(_ width: CGFloat, config: LayoutConfig, viewport: CGRect) -> ColumnWidthSpec {
    let strip = viewport.width - config.padding * 2 + config.gap
    guard strip > 0 else {
        return .points(width)
    }
    return .proportion((width + config.gap) / strip)
}

// MARK: - Move

/// MD-01: where a moved window lands, relative to the tile under the
/// pointer.
public enum MouseDropTarget: Equatable, Sendable {
    /// The tile's center: the two windows trade places.
    case swap(WindowID)
    /// A side edge: a column of its own left or right of the tile's column.
    case newColumn(beside: WindowID, after: Bool)
    /// The top or bottom edge: into the tile's column above or below it.
    case stack(beside: WindowID, below: Bool)
}

/// The share of a tile's width or height that counts as an edge.
public let mouseDropEdgeShare: CGFloat = 0.25

/// The drop target under `point` (Cocoa) among the tiles' `frames` (the
/// layout the drag started from, so the zones hold still while the strip
/// makes room). Side edges win over top and bottom ones. Nil over the
/// dragged window's own tile, in a gap or off every tile.
public func mouseDropTarget(at point: CGPoint, dragged: WindowID, frames: [WindowID: CGRect]) -> MouseDropTarget? {
    guard let (tile, frame) = frames
        .filter({ $0.value.contains(point) })
        .min(by: { ($0.key.pid, $0.key.elementID) < ($1.key.pid, $1.key.elementID) }),
        tile != dragged, frame.width > 0, frame.height > 0
    else {
        return nil
    }
    let x = (point.x - frame.minX) / frame.width
    let y = (point.y - frame.minY) / frame.height
    if x < mouseDropEdgeShare {
        return .newColumn(beside: tile, after: false)
    }
    if x > 1 - mouseDropEdgeShare {
        return .newColumn(beside: tile, after: true)
    }
    if y > 1 - mouseDropEdgeShare {
        return .stack(beside: tile, below: false)
    }
    if y < mouseDropEdgeShare {
        return .stack(beside: tile, below: true)
    }
    return .swap(tile)
}

/// `id` moved to `target`. Column widths stay with their columns; a window
/// alone in its column carries the column, a stacked one leaves with its
/// column's width. Height weights travel with the windows. The focus stays
/// on the window that had it. A target naming `id` itself, or a window not
/// in the workspace: unchanged. Passive (no focus intent); the caller
/// reflows.
public func movingWindow(_ id: WindowID, to target: MouseDropTarget, in workspace: Workspace) -> Workspace {
    let anchor: WindowID
    switch target {
    case .swap(let other), .newColumn(let other, _), .stack(let other, _):
        anchor = other
    }
    guard anchor != id,
          let source = workspace.columns.firstIndex(where: { $0.windows.contains(id) }),
          workspace.columns.contains(where: { $0.windows.contains(anchor) })
    else {
        return workspace
    }
    var next = workspace
    switch target {
    case .swap:
        let other = next.columns.firstIndex { $0.windows.contains(anchor) }!
        let row = next.columns[source].windows.firstIndex(of: id)!
        let otherRow = next.columns[other].windows.firstIndex(of: anchor)!
        let weight = next.columns[source].heightWeights.removeValue(forKey: id)
        let otherWeight = next.columns[other].heightWeights.removeValue(forKey: anchor)
        next.columns[source].windows[row] = anchor
        next.columns[other].windows[otherRow] = id
        next.columns[source].heightWeights[anchor] = otherWeight
        next.columns[other].heightWeights[id] = weight
    case .newColumn(_, let after):
        let carried: Column
        if next.columns[source].windows.count == 1 {
            carried = next.columns.remove(at: source)
        } else {
            carried = relabeled(leave(id, column: &next.columns[source]), in: next)
        }
        let other = next.columns.firstIndex { $0.windows.contains(anchor) }!
        next.columns.insert(carried, at: after ? other + 1 : other)
    case .stack(_, let below):
        if next.columns[source].windows.count == 1 {
            next.columns.remove(at: source)
        } else {
            _ = leave(id, column: &next.columns[source])
        }
        let other = next.columns.firstIndex { $0.windows.contains(anchor) }!
        let row = next.columns[other].windows.firstIndex(of: anchor)!
        next.columns[other].windows.insert(id, at: below ? row + 1 : row)
    }
    return keepingFocus(of: workspace, in: next)
}

/// Each column's focus on the window it had, the workspace's on its
/// focused window.
private func keepingFocus(of before: Workspace, in after: Workspace) -> Workspace {
    var result = after
    let focusedRows = Dictionary(
        before.columns.compactMap { column in column.focusedWindowID.map { (column.id, $0) } },
        uniquingKeysWith: { first, _ in first }
    )
    for index in result.columns.indices {
        let column = result.columns[index]
        if let window = focusedRows[column.id], let row = column.windows.firstIndex(of: window) {
            result.columns[index].focusedWindowIndex = row
        } else {
            result.columns[index].focusedWindowIndex = min(max(column.focusedWindowIndex, 0), max(column.windows.count - 1, 0))
        }
    }
    if let window = result.focusedWindow,
       let column = result.columns.firstIndex(where: { $0.windows.contains(window) }),
       let row = result.columns[column].windows.firstIndex(of: window)
    {
        result.focusedColumn = column
        result.columns[column].focusedWindowIndex = row
    } else if !result.columns.isEmpty {
        result.focusedColumn = min(max(result.focusedColumn, 0), result.columns.count - 1)
    }
    return result
}
