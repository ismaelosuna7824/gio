import CoreGraphics
import Foundation

/// NA-03: the close ghost fades out while it shrinks this fraction, over
/// `closeGhostDuration`, then the layer removes itself.
public let closeGhostDuration: TimeInterval = 0.15
public let closeGhostShrink: CGFloat = 0.06
/// An image older than this is not shown (the window may have changed).
public let closeGhostMaxImageAge: TimeInterval = 120

/// NA-03: where a closing window's ghost is drawn, or nil for none. Opt-in
/// (`enabled`), and only for a window that was in view (not minimized, more
/// than a parking sliver inside a viewport) with a fresh cached image: taken
/// at the frame the window still had (within `tolerance`), not too old.
/// Without an image there is no ghost; the neighbours' glide is unchanged.
public func closeGhostFrame(
    enabled: Bool,
    isMinimized: Bool,
    physical: CGRect?,
    cachedFrame: CGRect?,
    capturedAt: TimeInterval?,
    viewports: [CGRect],
    now: TimeInterval,
    maxAge: TimeInterval = closeGhostMaxImageAge,
    tolerance: CGFloat = 2
) -> CGRect? {
    guard enabled, !isMinimized, let physical, let cachedFrame, let capturedAt,
          now - capturedAt <= maxAge,
          abs(physical.minX - cachedFrame.minX) <= tolerance, abs(physical.minY - cachedFrame.minY) <= tolerance,
          abs(physical.width - cachedFrame.width) <= tolerance, abs(physical.height - cachedFrame.height) <= tolerance,
          viewports.contains(where: { isOnScreen(physical, viewport: $0) })
    else {
        return nil
    }
    return physical
}
