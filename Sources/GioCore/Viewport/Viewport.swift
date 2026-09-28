import CoreGraphics
import Foundation

/// Plan §10 viewport: the visible slice of the column strip. `offset` is the
/// content x showing at the view's left edge; `width` is the visible width.
/// The viewport never leaves the content bounds — every mutating path goes
/// through `clamped` or `ensureVisible`.
public struct Viewport: Equatable, Sendable {
    public var offset: CGFloat
    public var width: CGFloat

    public init(offset: CGFloat = 0, width: CGFloat) {
        self.offset = offset
        self.width = width
    }

    /// Pin the offset inside `[0, max(0, contentWidth - width)]`.
    /// Non-finite offsets reset to zero; degenerate widths pin to zero.
    public func clamped(contentWidth: CGFloat) -> Viewport {
        guard width.isFinite, width > 0, contentWidth.isFinite, contentWidth >= 0 else {
            return Viewport(offset: 0, width: width)
        }
        let safe = offset.isFinite ? offset : 0
        return Viewport(offset: min(max(safe, 0), max(0, contentWidth - width)), width: width)
    }

    /// Shift minimally so `range` (a column's content x-range) becomes
    /// visible, then clamp to bounds. Already-visible ranges never move.
    /// A range wider than the viewport pins to its start.
    public func ensureVisible(range: Range<CGFloat>, contentWidth: CGFloat) -> Viewport {
        var next = offset
        if range.upperBound - range.lowerBound > width {
            next = range.lowerBound
        } else if range.lowerBound < next {
            next = range.lowerBound
        } else if range.upperBound > next + width {
            next = range.upperBound - width
        }
        return Viewport(offset: next, width: width).clamped(contentWidth: contentWidth)
    }
}
