import CoreGraphics
import Foundation

/// FI-13: a window Gio no longer writes (it yielded to its app, FI-10) can
/// be left where Gio last parked it, off screen: a workspace hidden when the
/// window yielded keeps it at its parking sliver for good, and activating the
/// app shows nothing. When less than half of `frame` lies in `visible`, the
/// frame moved (size kept, capped to `visible`) to the nearest place fully
/// inside it; nil when it is already mostly on screen.
public func rescuedFrame(_ frame: CGRect, into visible: CGRect) -> CGRect? {
    guard frame.width > 0, frame.height > 0, visible.width > 0, visible.height > 0 else {
        return nil
    }
    let inside = frame.intersection(visible)
    let shown = inside.isNull ? 0 : inside.width * inside.height
    guard shown < frame.width * frame.height / 2 else {
        return nil
    }
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)
    let x = min(max(frame.minX, visible.minX), visible.maxX - width)
    let y = min(max(frame.minY, visible.minY), visible.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
}
