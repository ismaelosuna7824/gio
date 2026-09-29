import CoreGraphics
import Foundation

/// Plan §8 column identity. Adapter-assigned per session, like `WindowID`.
public struct ColumnID: Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// How a column's width is chosen. Proportions are resolved per display
/// viewport at layout time (Niri semantics), so the same spec adapts across
/// displays of different sizes; points are absolute.
public enum ColumnWidthSpec: Equatable, Sendable {
    /// The engine default (`default-column-width`).
    case standard
    /// Niri proportion of the strip: `p * (viewport - 2*padding + gap) - gap`.
    case proportion(CGFloat)
    case points(CGFloat)
}

/// Plan §8: one vertical stack of windows. `width` units are interpreted by
/// the layout engine (Phase 3); this type only stores them. A column may be
/// empty during transitions — `focusedWindowID` is nil then, never a crash.
public struct Column: Equatable, Sendable {
    public let id: ColumnID
    public var widthSpec: ColumnWidthSpec {
        // Any width change other than the maximize toggle itself forgets the
        // width to restore (the toggle re-sets `savedWidthSpec` afterwards).
        didSet { savedWidthSpec = nil }
    }
    /// Width to restore when a maximized column is toggled back; nil unless
    /// the column is currently maximized.
    public var savedWidthSpec: ColumnWidthSpec?
    /// Absolute points, or 0 for every non-point spec. Kept as the plain
    /// numeric view of `widthSpec` for legacy callers; setting positive
    /// points selects `.points`, anything else `.standard`.
    public var width: CGFloat {
        get {
            if case .points(let value) = widthSpec {
                return value
            }
            return 0
        }
        set {
            widthSpec = newValue > 0 ? .points(newValue) : .standard
        }
    }
    public var windows: [WindowID]
    public var focusedWindowIndex: Int
    /// Relative height weights per window; absent means 1.0. The layout
    /// engine distributes column height proportionally (Phase 3); resize
    /// operations (Phase 7) and moves maintain this map.
    public var heightWeights: [WindowID: CGFloat]

    public init(
        id: ColumnID,
        width: CGFloat,
        windows: [WindowID] = [],
        focusedWindowIndex: Int = 0,
        heightWeights: [WindowID: CGFloat] = [:],
        widthSpec: ColumnWidthSpec? = nil
    ) {
        self.id = id
        self.widthSpec = widthSpec ?? (width > 0 ? .points(width) : .standard)
        self.windows = windows
        self.focusedWindowIndex = focusedWindowIndex
        self.heightWeights = heightWeights
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
