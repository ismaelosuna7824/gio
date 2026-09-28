import Foundation

public enum TileLayoutError: Error, Equatable {
    case duplicateWindow(LegacyWindowID)
    case invalidBounds
    case invalidGap
    case insufficientSpace
}

/// A target frame only; applying it is the caller's responsibility.
public struct TileTarget: Equatable {
    public let window: LegacyWindowID
    public let frame: CGRect

    public init(window: LegacyWindowID, frame: CGRect) {
        self.window = window
        self.frame = frame
    }
}

/// Pure, ordered layout in CoreGraphics points. Equal axes split horizontally.
public enum TileLayout {
    public static func plan(
        windows: [LegacyWindowID], in bounds: CGRect, outerGap: CGFloat = 0, innerGap: CGFloat = 0
    ) throws -> [TileTarget] {
        var seen = Set<LegacyWindowID>()
        for window in windows where !seen.insert(window).inserted {
            throw TileLayoutError.duplicateWindow(window)
        }
        guard outerGap.isFinite, innerGap.isFinite, outerGap >= 0, innerGap >= 0 else {
            throw TileLayoutError.invalidGap
        }
        guard validFrame(bounds) else {
            throw TileLayoutError.invalidBounds
        }
        guard !windows.isEmpty else { return [] }
        let usable = bounds.insetBy(dx: outerGap, dy: outerGap)
        guard validFrame(usable) else {
            throw TileLayoutError.insufficientSpace
        }
        if outerGap > 0 {
            guard usable.minX > bounds.minX, usable.minY > bounds.minY,
                  usable.maxX < bounds.maxX, usable.maxY < bounds.maxY else {
                throw TileLayoutError.insufficientSpace
            }
        }
        return try split(windows[...], in: usable, gap: innerGap)
    }

    private static func validFrame(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0 &&
            rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func split(_ windows: ArraySlice<LegacyWindowID>, in rect: CGRect, gap: CGFloat) throws -> [TileTarget] {
        guard validFrame(rect) else { throw TileLayoutError.insufficientSpace }
        if windows.count == 1 { return [TileTarget(window: windows.first!, frame: rect)] }
        let horizontal = rect.width >= rect.height
        let length = horizontal ? rect.width : rect.height
        let half = (length - gap) / 2
        guard half.isFinite, half > 0 else { throw TileLayoutError.insufficientSpace }
        let firstRect: CGRect
        let secondRect: CGRect
        if horizontal {
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height)
            secondRect = CGRect(x: rect.minX + half + gap, y: rect.minY, width: half, height: rect.height)
        } else {
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: half)
            secondRect = CGRect(x: rect.minX, y: rect.minY + half + gap, width: rect.width, height: half)
        }
        guard validFrame(firstRect), validFrame(secondRect) else {
            throw TileLayoutError.insufficientSpace
        }
        if gap > 0 {
            let firstEdge = horizontal ? firstRect.maxX : firstRect.maxY
            let secondEdge = horizontal ? secondRect.minX : secondRect.minY
            guard secondEdge > firstEdge else { throw TileLayoutError.insufficientSpace }
        }
        let midpoint = windows.startIndex + (windows.count + 1) / 2
        return try split(windows[..<midpoint], in: firstRect, gap: gap)
            + split(windows[midpoint...], in: secondRect, gap: gap)
    }
}
