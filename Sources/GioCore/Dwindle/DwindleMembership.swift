import CoreGraphics
import Foundation

/// DW-01: what a workspace starts with (`[layout] default-layout`) and the
/// ratio new dwindle splits take (`[dwindle] default-split-ratio`).
public struct WorkspaceLayoutDefaults: Equatable, Sendable {
    public var kind: WorkspaceLayoutKind
    public var splitRatio: CGFloat

    public init(kind: WorkspaceLayoutKind = .scrolling, splitRatio: CGFloat = 1) {
        self.kind = kind
        self.splitRatio = clampedDwindleRatio(splitRatio)
    }
}

extension Workspace {
    /// DW-01: make the dwindle tree a faithful view of the columns, the one
    /// membership list. A scrolling workspace keeps no tree. A dwindle one:
    /// windows that left the columns leave the tree (their split collapses),
    /// new members split the selected leaf in column order (each new one
    /// becomes the selected leaf), the selection follows the focused window,
    /// a maximize ends once its window is no longer focused, and the
    /// columns become one window each in the tree's leaf order (a column
    /// keeps its id and width; the extra windows of a stacked column get
    /// new columns with the same width). Idempotent; never adds or drops a
    /// member.
    public mutating func reconcileDwindle(splitRatio: CGFloat) {
        guard layout == .dwindle else {
            if dwindle != DwindleState() {
                dwindle = DwindleState()
            }
            return
        }
        var members: [WindowID] = []
        var memberSet = Set<WindowID>()
        for column in columns {
            for id in column.windows where memberSet.insert(id).inserted {
                members.append(id)
            }
        }
        var leaves = Set<WindowID>()
        for id in dwindle.windows where !memberSet.contains(id) || !leaves.insert(id).inserted {
            // Not a member any more, or a leaf twice (a hand-built tree).
            dwindle.remove(id)
            leaves.remove(id)
        }
        let present = Set(dwindle.windows)
        for id in members where !present.contains(id) {
            dwindle.insert(id, ratio: splitRatio)
        }
        if let focused = focusedWindow, memberSet.contains(focused) {
            dwindle.selected = focused
        }
        if let maximized = dwindle.maximized, maximized != focusedWindow || !memberSet.contains(maximized) {
            dwindle.maximized = nil
        }
        rebuildColumns(in: dwindle.windows)
    }

    /// DW-01: this workspace laid out as `kind`, every window kept. To
    /// dwindle: a tree built from the column order (a spiral, each window
    /// splitting the previous one); to scrolling: one column per window in
    /// the tree's leaf order. The viewport starts at the left edge (the
    /// next pass reveals the focused column). Unchanged when already `kind`.
    public func settingLayout(_ kind: WorkspaceLayoutKind, splitRatio: CGFloat) -> Workspace {
        guard kind != layout else {
            return self
        }
        var next = self
        next.layout = kind
        next.dwindle = DwindleState()
        next.viewportOffset = 0
        next.reconcileDwindle(splitRatio: splitRatio)
        return next
    }

    private mutating func rebuildColumns(in order: [WindowID]) {
        var owner: [WindowID: Column] = [:]
        for column in columns {
            for id in column.windows where owner[id] == nil {
                owner[id] = column
            }
        }
        var used = Set<ColumnID>()
        var nextID = (columns.map(\.id.rawValue).max() ?? 0) + 1
        var rebuilt: [Column] = []
        for id in order {
            guard let source = owner[id] else {
                continue
            }
            if source.windows.count == 1, used.insert(source.id).inserted {
                var kept = source
                kept.focusedWindowIndex = 0
                rebuilt.append(kept)
                continue
            }
            var column: Column
            if source.windows.first == id, used.insert(source.id).inserted {
                column = Column(id: source.id, width: 0, windows: [id], widthSpec: source.widthSpec)
            } else {
                column = Column(id: ColumnID(nextID), width: 0, windows: [id], widthSpec: source.widthSpec)
                nextID += 1
            }
            column.savedWidthSpec = source.savedWidthSpec
            rebuilt.append(column)
        }
        if rebuilt != columns {
            columns = rebuilt
        }
        if let focused = focusedWindow, let index = columns.firstIndex(where: { $0.windows == [focused] }) {
            focusedColumn = index
        } else {
            focusedColumn = columns.isEmpty ? 0 : min(max(focusedColumn, 0), columns.count - 1)
        }
    }
}
