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
