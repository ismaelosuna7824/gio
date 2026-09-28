import CoreGraphics

/// Pure checks shared by AX reads and post-write verification.
public enum AXGeometryValidation {
    public static func isValidPosition(_ origin: CGPoint) -> Bool {
        origin.x.isFinite && origin.y.isFinite
    }

    public static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    public static func isValidFrame(origin: CGPoint, size: CGSize) -> Bool {
        isValidPosition(origin) && isValidSize(size)
    }

    /// Exact comparison for deciding writes; tolerance applies only to post-write verification.
    public static func changes(from current: CGRect, to target: CGRect) -> (size: Bool, position: Bool) {
        (current.size != target.size, current.origin != target.origin)
    }

    /// Write order for applying a frame change.
    ///
    /// Growing size-first from a tiled position can overflow the display and
    /// get clamped (e.g. restoring 1800pt wide from x=456 clamps the width),
    /// so any growth moves position-first. Shrinking size-first is safe and
    /// keeps the window on screen while it gets smaller. Equal sizes (moves
    /// or no-ops) stay on the size-first path.
    public enum ApplyOrder {
        case sizeFirst
        case positionFirst
    }

    public static func applyOrder(from current: CGRect, to target: CGRect) -> ApplyOrder {
        (target.width > current.width || target.height > current.height) ? .positionFirst : .sizeFirst
    }

    public static func matches(requested: CGRect, actual: CGRect) -> Bool {
        matches(requested: requested.origin, actual: actual.origin)
            && isValidSize(requested.size) && isValidSize(actual.size)
            && abs(requested.width - actual.width) <= 1
            && abs(requested.height - actual.height) <= 1
    }

    public static func matches(requested: CGPoint, actual: CGPoint) -> Bool {
        [requested.x, requested.y, actual.x, actual.y].allSatisfy(\.isFinite)
            && abs(actual.x - requested.x) <= 1 && abs(actual.y - requested.y) <= 1
    }
}
