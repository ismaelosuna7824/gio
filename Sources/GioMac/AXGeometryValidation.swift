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

    public static func matches(requested: CGPoint, actual: CGPoint) -> Bool {
        [requested.x, requested.y, actual.x, actual.y].allSatisfy(\.isFinite)
            && abs(actual.x - requested.x) <= 1 && abs(actual.y - requested.y) <= 1
    }
}
