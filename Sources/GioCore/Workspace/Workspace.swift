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

    public init(
        id: WorkspaceID,
        columns: [Column] = [],
        focusedColumn: Int = 0,
        focusedWindow: WindowID? = nil,
        viewportOffset: CGFloat = 0
    ) {
        self.id = id
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.focusedWindow = focusedWindow
        self.viewportOffset = viewportOffset
    }

    /// The focused column, or nil when the index is out of range.
    public var focusedColumnRef: Column? {
        guard focusedColumn >= 0, focusedColumn < columns.count else {
            return nil
        }
        return columns[focusedColumn]
    }
}
