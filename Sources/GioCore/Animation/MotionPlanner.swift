import CoreGraphics
import Foundation

/// A window counts as on screen when more than a parking sliver of it is
/// inside the viewport: the 1pt strip a parked window keeps inside its
/// display must not make it look visible on an edge-to-edge viewport.
func isOnScreen(_ frame: CGRect, viewport: CGRect) -> Bool {
    let inside = frame.intersection(viewport)
    return !inside.isNull && inside.width > parkingSliver * 2 && inside.height > 0
}

/// MO-04 pure planning: which windows animate for one display's reflow and
/// between which physical frames. Only windows whose current OR target frame
/// is on screen animate (typically 2-4); everything else (parked to parked)
/// is left to the final reconcile, which jumps it as before.
///
/// - `current`: the physical frame each window has right now (last applied,
///   or the sampled mid-flight frame when retargeting). Windows without one
///   cannot start anywhere and jump.
/// - Entering windows start at their parked edge, which is already on the
///   correct side. Leaving windows end at their parked edge; a corner-parked
///   window slides off the right edge at its own height first, and the final
///   reconcile writes the real corner target.
public func planMotion(
    current: [WindowID: CGRect],
    visible: [WindowID: CGRect],
    parked: [WindowID: ParkedTarget],
    viewport: CGRect,
    duration: TimeInterval,
    easing: AnimationEasing = .easeOut,
    tolerance: CGFloat = 1
) -> [WindowAnimation] {
    var animations: [WindowAnimation] = []
    for id in Set(visible.keys).union(parked.keys).sorted() {
        guard let start = current[id] else {
            continue
        }
        let end: CGRect
        if let target = parked[id] {
            end = slideOutTarget(start: start, parked: target)
        } else if let target = visible[id] {
            end = target
        } else {
            continue
        }
        guard isOnScreen(start, viewport: viewport) || isOnScreen(end, viewport: viewport),
              differs(start, end, tolerance)
        else {
            continue
        }
        animations.append(WindowAnimation(id: id, from: start, to: end, duration: duration, easing: easing))
    }
    return animations
}

private func slideOutTarget(start: CGRect, parked: ParkedTarget) -> CGRect {
    guard parked.edge == .corner else {
        return parked.frame
    }
    return CGRect(
        x: parked.frame.minX, y: start.minY,
        width: parked.frame.width, height: parked.frame.height
    )
}

private func differs(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
    abs(a.origin.x - b.origin.x) > tolerance || abs(a.origin.y - b.origin.y) > tolerance
        || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
}
