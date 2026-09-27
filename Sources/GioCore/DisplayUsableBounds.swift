import CoreGraphics

/// Converts one screen's bottom-left AppKit visible frame into global top-left CG coordinates.
/// Frames must belong to the same display; never fall back to the full display bounds.
public enum DisplayUsableBounds {
    public static func convert(screenFrame: CGRect, visibleFrame: CGRect, displayBounds: CGRect) -> CGRect? {
        guard valid(screenFrame), valid(visibleFrame), valid(displayBounds),
              screenFrame.contains(visibleFrame),
              screenFrame.size == displayBounds.size else { return nil }
        let result = CGRect(x: displayBounds.minX + visibleFrame.minX - screenFrame.minX,
                            y: displayBounds.minY + screenFrame.maxY - visibleFrame.maxY,
                            width: visibleFrame.width, height: visibleFrame.height)
        guard valid(result), displayBounds.contains(result) else { return nil }
        return result
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}
