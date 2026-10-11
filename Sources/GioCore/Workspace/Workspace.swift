import CoreGraphics
import Foundation

/// Plan §8 workspace identity. Adapter-assigned per session, like `WindowID`.
public struct WorkspaceID: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Plan §8: the Niri-style workspace model. A horizontal strip of columns;
/// the monitor is only a viewport over it (`viewportOffset`). Pure data:
/// no AXUIElement, NSWindow, CGWindow or AppKit may ever appear in this
/// layer — the compiler and the `GioCore` import graph enforce it.
public struct Workspace: Equatable, Sendable {
    public let id: WorkspaceID
    public var columns: [Column]
    public var focusedColumn: Int
    public var focusedWindow: WindowID?
    public var viewportOffset: CGFloat
    /// NW-02: set for a `[[workspace]]` (persistent, never pruned); nil for
    /// a dynamic workspace. Owned by `WorkspaceManager`: `update` keeps it.
    public var name: String?
    /// DW-01: scrolling strip (the default) or dwindle tree. Switch it with
    /// `settingLayout(_:splitRatio:)`, which keeps the windows.
    public var layout: WorkspaceLayoutKind
    /// DW-01: the dwindle tree, a view of `columns` (the one membership
    /// list); empty while `layout` is `.scrolling`. `reconcileDwindle`
    /// (run by `WorkspaceManager` on every write) keeps it in sync.
    public var dwindle: DwindleState

    public init(
        id: WorkspaceID,
        columns: [Column] = [],
        focusedColumn: Int = 0,
        focusedWindow: WindowID? = nil,
        viewportOffset: CGFloat = 0,
        name: String? = nil,
        layout: WorkspaceLayoutKind = .scrolling,
        dwindle: DwindleState = DwindleState()
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.focusedWindow = focusedWindow
        self.viewportOffset = viewportOffset
        self.layout = layout
        self.dwindle = dwindle
    }

    /// Every member window in column order (the dwindle tree's leaf order
    /// for a dwindle workspace).
    public var windows: [WindowID] {
        columns.flatMap(\.windows)
    }

    /// The focused column, or nil when the index is out of range.
    public var focusedColumnRef: Column? {
        guard focusedColumn >= 0, focusedColumn < columns.count else {
            return nil
        }
        return columns[focusedColumn]
    }

    /// Remove every listed window (reaped processes, stale records),
    /// dropping emptied columns and repairing focus: a surviving focused
    /// window keeps the focus and the focused column follows it to its
    /// (possibly shifted) index; otherwise focus falls to the neighbor, then
    /// to the column focus, then to nil. Recovery's pruning path; move
    /// operations keep their own single-index repair.
    public mutating func stripWindows(_ ids: Set<WindowID>) {
        guard !ids.isEmpty else {
            return
        }
        for index in columns.indices {
            let oldFocused = columns[index].focusedWindowID
            columns[index].windows.removeAll { ids.contains($0) }
            columns[index].heightWeights = columns[index].heightWeights.filter {
                !ids.contains($0.key)
            }
            if let oldFocused, !ids.contains(oldFocused),
               let at = columns[index].windows.firstIndex(of: oldFocused)
            {
                columns[index].focusedWindowIndex = at
            } else {
                columns[index].focusedWindowIndex = min(
                    columns[index].focusedWindowIndex,
                    max(0, columns[index].windows.count - 1)
                )
            }
        }
        columns.removeAll { $0.windows.isEmpty }
        if columns.isEmpty {
            focusedColumn = 0
            focusedWindow = nil
            return
        }
        focusedColumn = min(max(focusedColumn, 0), columns.count - 1)
        if let focused = focusedWindow,
           let row = columns.firstIndex(where: { $0.windows.contains(focused) })
        {
            focusedColumn = row
            return
        }
        focusedWindow = columns[focusedColumn].focusedWindowID
    }
}
