import CoreGraphics

/// The frame as the logs print it: `(x,y,w,h)` in whole points, matching the
/// CLI's window lines and the reconcile counters. Ids and apps only; a frame
/// never carries a title (invariant 5).
public func logFrame(_ frame: CGRect) -> String {
    let x = Int(frame.origin.x)
    let y = Int(frame.origin.y)
    let width = Int(frame.size.width)
    let height = Int(frame.size.height)
    return "(\(x),\(y),\(width),\(height))"
}
