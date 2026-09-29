import CoreGraphics
import Foundation

/// PA-03: the motion timer follows the display, not a fixed 120 Hz.
/// Seconds between frames for a display refreshing at `framesPerSecond`.
/// ProMotion tops out at 120 Hz (faster panels are not chased), unknown or
/// non-positive rates mean 60 Hz, and very low rates still tick at 30 Hz.
public func frameInterval(for framesPerSecond: Int) -> TimeInterval {
    let fallback = 60
    let rate = framesPerSecond > 0 ? min(max(framesPerSecond, 30), 120) : fallback
    return 1.0 / Double(rate)
}

/// A display frame and its refresh rate, read on the main thread
/// (`NSScreen.maximumFramesPerSecond`) and handed to the session.
public struct DisplayRefresh: Equatable, Sendable {
    public let frame: CGRect
    public let framesPerSecond: Int

    public init(frame: CGRect, framesPerSecond: Int) {
        self.frame = frame
        self.framesPerSecond = framesPerSecond
    }
}

/// Refresh rate for a motion: the fastest display holding any moving window
/// (start or end frame), 60 when no display is known to hold them.
public func motionRefreshRate(animations: [WindowAnimation], displays: [DisplayRefresh]) -> Int {
    var best = 0
    for animation in animations {
        for frame in [animation.from, animation.to] {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let display = displays.first(where: { $0.frame.contains(center) }) {
                best = max(best, display.framesPerSecond)
            }
        }
    }
    return best > 0 ? best : 60
}
