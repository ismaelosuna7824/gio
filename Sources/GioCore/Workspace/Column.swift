import CoreGraphics
import Foundation

/// Plan §8 column identity. Adapter-assigned per session, like `WindowID`.
public struct ColumnID: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Plan §8: one vertical stack of windows. `width` units are interpreted by
/// the layout engine (Phase 3); this type only stores them. A column may be
/// empty during transitions — `focusedWindowID` is nil then, never a crash.
public struct Column: Equatable, Sendable {
    public let id: ColumnID
    public var width: CGFloat
    public var windows: [WindowID]
    public var focusedWindowIndex: Int

    public init(
        id: ColumnID,
        width: CGFloat,
        windows: [WindowID] = [],
        focusedWindowIndex: Int = 0
    ) {
        self.id = id
        self.width = width
        self.windows = windows
        self.focusedWindowIndex = focusedWindowIndex
    }

    /// The focused window, or nil when the column is empty or the index is
    /// out of range.
    public var focusedWindowID: WindowID? {
        guard focusedWindowIndex >= 0, focusedWindowIndex < windows.count else {
            return nil
        }
        return windows[focusedWindowIndex]
    }
}
