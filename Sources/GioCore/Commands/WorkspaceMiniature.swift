import CoreGraphics
import Foundation

/// DD-02: the geometry behind the Overview's live workspace miniature.
/// The host captures `WorkspaceStripFact` from the layout it already runs
/// (session queue, no AX); `workspaceMiniature` turns it into unit rects.

/// One tiled window of the strip, vertical extent relative to the viewport.
public struct StripWindowFact: Equatable, Sendable {
    public let id: String
    public let application: String
    public let top: CGFloat
    public let height: CGFloat

    public init(id: String, application: String, top: CGFloat, height: CGFloat) {
        self.id = id
        self.application = application
        self.top = top
        self.height = height
    }
}

/// One column in strip (content) coordinates: `x` from the strip's start.
public struct StripColumnFact: Equatable, Sendable {
    public let x: CGFloat
    public let width: CGFloat
    public let windows: [StripWindowFact]

    public init(x: CGFloat, width: CGFloat, windows: [StripWindowFact]) {
        self.x = x
        self.width = width
        self.windows = windows
    }
}

/// The focused display's current workspace as a horizontal strip.
public struct WorkspaceStripFact: Equatable, Sendable {
    public let displayID: UInt32
    /// 1-based index of the workspace in its display's stack.
    public let workspace: Int
    public let viewportWidth: CGFloat
    public let viewportHeight: CGFloat
    public let viewportOffset: CGFloat
    public let contentWidth: CGFloat
    public let columns: [StripColumnFact]
    public let focusedColumn: Int?
    public let focusedWindowID: String?

    public init(
        displayID: UInt32, workspace: Int, viewportWidth: CGFloat, viewportHeight: CGFloat,
        viewportOffset: CGFloat, contentWidth: CGFloat, columns: [StripColumnFact],
        focusedColumn: Int?, focusedWindowID: String?
    ) {
        self.displayID = displayID
        self.workspace = workspace
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.viewportOffset = viewportOffset
        self.contentWidth = contentWidth
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.focusedWindowID = focusedWindowID
    }
}

/// The `WindowFact.id` spelling of a window.
public func windowFactID(_ id: WindowID) -> String {
    "\(id.pid):\(id.elementID)"
}

/// Strip facts from a tiled workspace and the layout computed for it.
/// Frames are shifted back by the viewport offset into strip coordinates.
/// DW-04: a dwindle workspace (one window per column, `layout` from
/// `workspaceLayoutResult`) gives one fact per tile. `top` is measured from
/// the viewport's top edge so the drawing (y down) matches the screen (Cocoa
/// y up), for the strip's stacked columns too.
public func makeWorkspaceStrip(
    workspace: Workspace, layout: LayoutResult, viewport: CGRect, displayID: UInt32, index: Int,
    application: (WindowID) -> String
) -> WorkspaceStripFact {
    var columns: [StripColumnFact] = []
    var focusedColumn: Int?
    for column in workspace.columns {
        let frames = column.windows.compactMap { id in layout.frames[id].map { (id, $0) } }
        guard let first = frames.first?.1 else {
            continue
        }
        if let focused = workspace.focusedWindow, column.windows.contains(focused) {
            focusedColumn = columns.count
        }
        columns.append(StripColumnFact(
            x: first.minX - viewport.minX + layout.viewportOffset,
            width: first.width,
            windows: frames.map { id, frame in
                StripWindowFact(
                    id: windowFactID(id), application: application(id),
                    top: viewport.maxY - frame.maxY, height: frame.height
                )
            }
        ))
    }
    if focusedColumn == nil, !columns.isEmpty {
        focusedColumn = min(max(workspace.focusedColumn, 0), columns.count - 1)
    }
    let focusedWindow = workspace.focusedWindow.flatMap { id in
        columns.isEmpty ? nil : windowFactID(id)
    }
    return WorkspaceStripFact(
        displayID: displayID, workspace: index, viewportWidth: viewport.width,
        viewportHeight: viewport.height, viewportOffset: layout.viewportOffset,
        contentWidth: layout.contentWidth, columns: columns, focusedColumn: focusedColumn,
        focusedWindowID: focusedWindow
    )
}

/// One window tile of the miniature; `rect` is in unit space (x over the
/// strip span, y over the viewport height).
public struct MiniatureTile: Equatable, Sendable, Identifiable {
    public let id: String
    public let application: String
    public let initials: String
    public let rect: CGRect
    public let column: Int
    public let isFocusedColumn: Bool
    public let isFocusedWindow: Bool
    /// The column lies entirely outside the viewport (Gio parks it).
    public let isParked: Bool
}

public struct WorkspaceMiniature: Equatable, Sendable {
    public let tiles: [MiniatureTile]
    /// The display's viewport over the strip, in unit space.
    public let viewport: CGRect
    /// Strip span width over viewport height; the canvas keeps this aspect.
    public let aspectRatio: CGFloat
}

/// Normalize a strip for drawing. The span is the wider of the content and
/// the viewport (a short strip still shows the whole screen).
public func workspaceMiniature(_ strip: WorkspaceStripFact) -> WorkspaceMiniature {
    let height = max(strip.viewportHeight, 1)
    let span = max(strip.contentWidth, strip.viewportWidth, strip.viewportOffset + strip.viewportWidth, 1)
    let viewStart = strip.viewportOffset
    let viewEnd = strip.viewportOffset + strip.viewportWidth
    var tiles: [MiniatureTile] = []
    for (index, column) in strip.columns.enumerated() {
        let overlap = min(column.x + column.width, viewEnd) - max(column.x, viewStart)
        let parked = overlap < 1
        let focusedColumn = index == strip.focusedColumn
        for window in column.windows {
            tiles.append(MiniatureTile(
                id: window.id, application: window.application,
                initials: appInitials(window.application),
                rect: CGRect(
                    x: column.x / span, y: window.top / height,
                    width: column.width / span, height: window.height / height
                ),
                column: index, isFocusedColumn: focusedColumn,
                isFocusedWindow: window.id == strip.focusedWindowID, isParked: parked
            ))
        }
    }
    return WorkspaceMiniature(
        tiles: tiles,
        viewport: CGRect(x: viewStart / span, y: 0, width: strip.viewportWidth / span, height: 1),
        aspectRatio: span / height
    )
}

/// Tile label when no app icon is available: first letter of up to two
/// words, uppercased.
public func appInitials(_ application: String) -> String {
    let words = application.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
    let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "?" : letters.joined()
}

// MARK: - Window list

/// Overview window list section: one workspace (or the unassigned rest).
public struct WindowGroup: Equatable, Sendable, Identifiable {
    public let workspace: Int?
    public let title: String
    public let isActive: Bool
    public let rows: [WindowRow]
    public var id: String { workspace.map(String.init) ?? "other" }
}

/// Groups `windowRows` output (already ordered) by workspace, numbered
/// workspaces ascending, unassigned windows last.
public func groupWindowRows(_ rows: [WindowRow], activeWorkspace: Int?) -> [WindowGroup] {
    var order: [Int?] = []
    var buckets: [Int?: [WindowRow]] = [:]
    for row in rows {
        if buckets[row.workspace] == nil {
            order.append(row.workspace)
        }
        buckets[row.workspace, default: []].append(row)
    }
    let sorted = order.sorted { lhs, rhs in
        switch (lhs, rhs) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        default: return false
        }
    }
    return sorted.map { workspace in
        WindowGroup(
            workspace: workspace,
            title: workspace.map { "Workspace \($0)" } ?? "Other windows",
            isActive: workspace != nil && workspace == activeWorkspace,
            rows: buckets[workspace] ?? []
        )
    }
}

public struct WindowCounts: Equatable, Sendable {
    public let total: Int
    public let tiled: Int
    public let floating: Int
    public let fullscreen: Int
    public let minimized: Int
    public let hidden: Int

    public init(total: Int, tiled: Int, floating: Int, fullscreen: Int, minimized: Int, hidden: Int) {
        self.total = total
        self.tiled = tiled
        self.floating = floating
        self.fullscreen = fullscreen
        self.minimized = minimized
        self.hidden = hidden
    }

    /// `2 tiled · 1 floating`, zero counts omitted.
    public var detail: String {
        let parts = [
            (tiled, "tiled"), (floating, "floating"), (fullscreen, "fullscreen"),
            (minimized, "minimized"), (hidden, "hidden"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "None managed" : parts.joined(separator: " · ")
    }
}

public func windowCounts(_ rows: [WindowRow]) -> WindowCounts {
    var tiled = 0, floating = 0, fullscreen = 0, minimized = 0, hidden = 0
    for row in rows {
        switch row.state {
        case .tiled: tiled += 1
        case .floating: floating += 1
        case .fullscreen: fullscreen += 1
        case .minimized: minimized += 1
        case .hidden: hidden += 1
        }
    }
    return WindowCounts(
        total: rows.count, tiled: tiled, floating: floating, fullscreen: fullscreen,
        minimized: minimized, hidden: hidden
    )
}
