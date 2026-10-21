import CoreGraphics
import Foundation
import GioCore

/// WO-01: a captured window image for the overview, handed from the
/// session's capture task to the main thread. Equal when it is the same
/// image (the panel redraws a tile only when its image changed).
public struct OverviewThumbnail: @unchecked Sendable, Equatable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }

    public static func == (lhs: OverviewThumbnail, rhs: OverviewThumbnail) -> Bool {
        lhs.image === rhs.image
    }
}

/// Thumbnails are drawn at roughly a third of the display, so a capture
/// never needs more than this many pixels per point.
public let overviewThumbnailScale: CGFloat = 0.75

/// Why the overview closed (logged).
public enum OverviewDismissReason: String, Sendable {
    case escape, toggle, resignKey, pick, background
}

/// Keys the panel hands to the model.
public enum OverviewKey: Equatable, Sendable {
    case step(OverviewStep)
    case enter
    case escape
    case digit(Int)
}

/// One workspace row: its label and the strip drawn to scale.
public struct WorkspaceOverviewRow: Equatable, Identifiable, Sendable {
    public let index: Int
    public let title: String
    public let icon: String?
    public let color: String?
    public let isActive: Bool
    public let miniature: WorkspaceMiniature

    public var id: Int { index }
}

/// Rows in stack order, named from the display's stack summary ("1 · Code").
public func workspaceOverviewRows(_ facts: WorkspaceOverviewFacts, stack: [WorkspaceEntry]) -> [WorkspaceOverviewRow] {
    facts.strips.map { strip in
        let entry = stack.first { $0.index == strip.workspace }
        return WorkspaceOverviewRow(
            index: strip.workspace,
            title: entry.map(workspaceTitle) ?? "Workspace \(strip.workspace)",
            icon: entry?.icon, color: entry?.color,
            isActive: strip.workspace == facts.activeWorkspace,
            miniature: workspaceMiniature(strip)
        )
    }
}

/// Row height that fits every workspace in `available` points (with
/// `spacing` between rows), clamped to `minimum...maximum`. Below the
/// minimum the rows scroll instead of shrinking further.
public func overviewRowHeight(
    rows: Int, available: CGFloat, spacing: CGFloat, minimum: CGFloat, maximum: CGFloat
) -> CGFloat {
    guard rows > 0 else {
        return maximum
    }
    let fitting = (available - spacing * CGFloat(rows - 1)) / CGFloat(rows)
    return min(max(fitting, minimum), maximum)
}

/// A row's canvas: the strip's aspect ratio (at least 0.1) fitted in the
/// row height and the width left beside the label. Empty, never negative,
/// while the panel has no size yet (SwiftUI's first layout pass can measure
/// zero, and a negative frame is invalid).
public func overviewCanvasSize(aspectRatio: CGFloat, height: CGFloat, maxWidth: CGFloat) -> CGSize {
    let aspect = aspectRatio.isFinite ? max(aspectRatio, 0.1) : 0.1
    let canvasHeight = min(height, maxWidth / aspect)
    guard canvasHeight.isFinite, canvasHeight > 0 else {
        return .zero
    }
    return CGSize(width: canvasHeight * aspect, height: canvasHeight)
}

// MARK: - Drag and drop

/// A drawn tile for the drop math: its strip column (from the facts, so the
/// windows of a stacked column share it) and its rect in the panel's space.
public struct OverviewDropTile: Equatable, Sendable {
    public let windowID: String
    public let column: Int
    public let rect: CGRect

    public init(windowID: String, column: Int, rect: CGRect) {
        self.windowID = windowID
        self.column = column
        self.rect = rect
    }
}

/// A drawn row for the drop math, in the panel's space: `frame` is the band
/// a pointer targets this workspace in, `canvas` the strip drawing.
public struct OverviewDropRow: Equatable, Sendable {
    public let workspace: Int
    public let frame: CGRect
    public let canvas: CGRect
    public let tiles: [OverviewDropTile]

    public init(workspace: Int, frame: CGRect, canvas: CGRect, tiles: [OverviewDropTile]) {
        self.workspace = workspace
        self.frame = frame
        self.canvas = canvas
        self.tiles = tiles
    }
}

/// One strip column's horizontal extent (the union of its tiles).
private struct OverviewDropColumn {
    let column: Int
    var minX: CGFloat
    var maxX: CGFloat
}

/// The row's columns in strip order, each once however many tiles it stacks.
private func overviewDropColumns(_ tiles: [OverviewDropTile]) -> [OverviewDropColumn] {
    var columns: [Int: OverviewDropColumn] = [:]
    for tile in tiles {
        if var column = columns[tile.column] {
            column.minX = min(column.minX, tile.rect.minX)
            column.maxX = max(column.maxX, tile.rect.maxX)
            columns[tile.column] = column
        } else {
            columns[tile.column] = OverviewDropColumn(column: tile.column, minX: tile.rect.minX, maxX: tile.rect.maxX)
        }
    }
    return columns.values.sorted { $0.column < $1.column }
}

/// Where a tile dropped at `point` goes: the row under the point, before
/// the first column whose middle is right of the point, else after the
/// last (an empty row takes column 0). Nil outside every row (cancel).
public func overviewDropTarget(windowID: String, at point: CGPoint, rows: [OverviewDropRow]) -> OverviewMove? {
    guard let row = rows.first(where: { $0.frame.contains(point) }) else {
        return nil
    }
    let columns = overviewDropColumns(row.tiles)
    let column = columns.first { ($0.minX + $0.maxX) / 2 > point.x }?.column
        ?? columns.last.map { $0.column + 1 }
        ?? 0
    return OverviewMove(windowID: windowID, workspace: row.workspace, column: column)
}

/// The insertion bar for `move` in its row: centred in the gap before the
/// target column (just outside the first or last one), canvas high. Nil
/// for an empty row, which is highlighted whole instead.
public func overviewInsertionBar(_ move: OverviewMove, in row: OverviewDropRow, width: CGFloat) -> CGRect? {
    let columns = overviewDropColumns(row.tiles)
    guard let first = columns.first, let last = columns.last else {
        return nil
    }
    /// Tiles are inset 3 pt, so neighbours sit 6 pt apart.
    let edge: CGFloat = 3
    let x: CGFloat
    if let next = columns.firstIndex(where: { $0.column >= move.column }) {
        x = next == 0 ? first.minX - edge : (columns[next - 1].maxX + columns[next].minX) / 2
    } else {
        x = last.maxX + edge
    }
    return CGRect(x: x - width / 2, y: row.canvas.minY, width: width, height: row.canvas.height)
}

/// The pointer side of a tile drag, published apart from the model so only
/// the drag overlay redraws while the pointer moves.
@MainActor
final class OverviewDragState: ObservableObject {
    /// The pointer in the panel's space while a tile is lifted.
    @Published private(set) var location: CGPoint?
    /// Where the lifted tile would land; nil over no row.
    @Published private(set) var target: OverviewMove?
    private(set) var windowID: String?
    /// The gesture's start point, which tells one drag from the next.
    private(set) var start: CGPoint?
    /// The pointer's offset from the lifted tile's top-left corner.
    private(set) var grab: CGSize = .zero
    private(set) var size: CGSize = .zero
    /// The rows as drawn (the view keeps these current; not published).
    var rows: [OverviewDropRow] = []

    func lift(_ id: String, start: CGPoint) {
        let rect = rows.lazy.flatMap(\.tiles).first { $0.windowID == id }?.rect
            ?? CGRect(origin: start, size: .zero)
        windowID = id
        self.start = start
        grab = CGSize(width: start.x - rect.minX, height: start.y - rect.minY)
        size = rect.size
    }

    func update(_ location: CGPoint) -> OverviewMove? {
        guard let windowID else {
            return nil
        }
        let target = overviewDropTarget(windowID: windowID, at: location, rows: rows)
        self.location = location
        if self.target != target {
            self.target = target
        }
        return target
    }

    func clear() {
        windowID = nil
        start = nil
        location = nil
        target = nil
    }
}

/// Asks the session to move a window; completes on the main thread with the
/// display's fresh facts, nil when they could not be built.
public typealias OverviewMoveRequest = (OverviewMove, @escaping @Sendable (WorkspaceOverviewFacts?) -> Void) -> Void

/// The overview's state for one presentation: rows, selection, the
/// thumbnails as they land. Picking closes the panel first, then asks the
/// session (a window that vanished meanwhile falls back to its workspace).
/// Dragging a tile moves its window and redraws the rows in place.
@MainActor
public final class WorkspaceOverviewModel: ObservableObject {
    @Published public private(set) var facts: WorkspaceOverviewFacts
    @Published public private(set) var rows: [WorkspaceOverviewRow]
    @Published public private(set) var selection: OverviewSelection
    @Published public private(set) var thumbnails: [String: OverviewThumbnail] = [:]
    /// The dragged window, then the moved one until the session answers.
    @Published public private(set) var liftedWindowID: String?
    let drag = OverviewDragState()
    var dismiss: ((OverviewDismissReason) -> Void)?
    private let stack: [WorkspaceEntry]
    private let titles: [String: String]
    private let focusWindow: (String) -> Bool
    private let focusWorkspace: (Int) -> Void
    private let moveWindow: OverviewMoveRequest
    private var moving = false
    /// Escape ended this gesture; its remaining events are ignored.
    private var cancelledDragStart: CGPoint?

    public init(
        facts: WorkspaceOverviewFacts, stack: [WorkspaceEntry], titles: [String: String],
        focusWindow: @escaping (String) -> Bool, focusWorkspace: @escaping (Int) -> Void,
        move: @escaping OverviewMoveRequest = { _, done in done(nil) }
    ) {
        self.facts = facts
        self.stack = stack
        rows = workspaceOverviewRows(facts, stack: stack)
        selection = facts.initialSelection
        self.titles = titles
        self.focusWindow = focusWindow
        self.focusWorkspace = focusWorkspace
        moveWindow = move
    }

    /// Every window the rows draw, in row then reading order.
    public var windowIDs: [String] {
        facts.strips.flatMap(overviewWindowOrder)
    }

    /// The window's title for its tile (UI only; never logged).
    public func title(of id: String) -> String? {
        titles[id].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Thumbnails arrive in batches (cached first, then fresh captures);
    /// each merges into what the panel has, the later image winning.
    public func setThumbnails(_ thumbnails: [String: OverviewThumbnail]) {
        guard !thumbnails.isEmpty else {
            return
        }
        self.thumbnails.merge(thumbnails) { _, later in later }
    }

    /// The pointer moved over a tile or row. Ignored while a tile is lifted,
    /// so the selection stays on it.
    public func hover(_ selection: OverviewSelection) {
        if liftedWindowID == nil, self.selection != selection {
            self.selection = selection
        }
    }

    /// True when the key was the overview's.
    @discardableResult
    public func handle(_ key: OverviewKey) -> Bool {
        switch key {
        case .step(let step):
            selection = facts.selection(selection, stepping: step)
        case .enter:
            pick(selection)
        case .escape:
            if !cancelDrag() {
                dismiss?(.escape)
            }
        case .digit(let index):
            guard facts.strip(index) != nil else {
                return false
            }
            pick(OverviewSelection(workspace: index, windowID: nil))
        }
        return true
    }

    public func pick(_ selection: OverviewSelection) {
        dismiss?(.pick)
        if let id = selection.windowID, focusWindow(id) {
            return
        }
        focusWorkspace(selection.workspace)
    }

    // MARK: Dragging

    /// A tile's drag gesture moved (past its minimum distance); `start`
    /// identifies the gesture. A new gesture lifts its tile, unless a move
    /// is still waiting for the session.
    func dragChanged(_ id: String, workspace: Int, start: CGPoint, location: CGPoint) {
        if let cancelled = cancelledDragStart {
            guard cancelled != start else {
                return
            }
            cancelledDragStart = nil
        }
        guard !moving else {
            return
        }
        if drag.windowID != id || drag.start != start {
            liftedWindowID = id
            selection = OverviewSelection(workspace: workspace, windowID: id)
            drag.lift(id, start: start)
        }
        _ = drag.update(location)
    }

    /// The gesture ended: inside a row the window moves there, elsewhere the
    /// drag is cancelled.
    func dragEnded(_ id: String, start: CGPoint, location: CGPoint) {
        if cancelledDragStart == start {
            cancelledDragStart = nil
            return
        }
        guard !moving, drag.windowID == id, drag.start == start else {
            return
        }
        let target = drag.update(location)
        drag.clear()
        guard let target else {
            liftedWindowID = nil
            return
        }
        move(target)
    }

    /// Escape while dragging: drop nothing, keep the panel. False when no
    /// tile is lifted.
    private func cancelDrag() -> Bool {
        guard !moving, liftedWindowID != nil else {
            return false
        }
        cancelledDragStart = drag.start
        drag.clear()
        liftedWindowID = nil
        return true
    }

    /// Moves the window through the session, then redraws the rows from the
    /// fresh facts with the selection on it (nil facts keep the old rows).
    public func move(_ move: OverviewMove) {
        liftedWindowID = move.windowID
        moving = true
        moveWindow(move) { [weak self] facts in
            MainActor.assumeIsolated {
                self?.moved(move.windowID, facts: facts)
            }
        }
    }

    private func moved(_ id: String, facts: WorkspaceOverviewFacts?) {
        moving = false
        liftedWindowID = nil
        guard let facts else {
            return
        }
        self.facts = facts
        rows = workspaceOverviewRows(facts, stack: stack)
        if let strip = facts.strips.first(where: { overviewWindowOrder($0).contains(id) }) {
            selection = OverviewSelection(workspace: strip.workspace, windowID: id)
        } else {
            selection = facts.selection(onWorkspace: selection.workspace) ?? facts.initialSelection
        }
    }
}
