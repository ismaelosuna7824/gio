import CoreGraphics
import Foundation

/// WR-05: a window rule's `min-width` / `max-width` (points). The layout
/// clamps the width of the column holding the window; the app's own
/// minimum (the learned minimum size, FI-02) still wins afterwards.
public struct ColumnWidthLimits: Equatable, Sendable {
    public var min: CGFloat?
    public var max: CGFloat?

    public init(min: CGFloat?, max: CGFloat?) {
        self.min = min
        self.max = max
    }

    /// Nil when neither bound is set (no limits to keep).
    public static func from(min: CGFloat?, max: CGFloat?) -> ColumnWidthLimits? {
        min == nil && max == nil ? nil : ColumnWidthLimits(min: min, max: max)
    }

    /// The limits of a column stacking several windows: the largest minimum
    /// and the smallest maximum.
    public static func combined(_ limits: [ColumnWidthLimits]) -> ColumnWidthLimits {
        ColumnWidthLimits(
            min: limits.compactMap(\.min).max(),
            max: limits.compactMap(\.max).min()
        )
    }

    /// `width` within the bounds; the minimum wins a conflict.
    public func clamp(_ width: CGFloat) -> CGFloat {
        var result = width
        if let max {
            result = Swift.min(result, max)
        }
        if let min {
            result = Swift.max(result, min)
        }
        return result
    }
}
