import CoreGraphics
import Foundation

/// NC-07: what a workspace switch needs beyond `planMotion`.
/// - `prepositions`: instant writes made BEFORE the player starts, placing a
///   hidden incoming window directly below its target frame (fully past the
///   bottom edge, so the jump is invisible). The player's frames then only
///   change the vertical position, which keeps the lean writer honest about
///   what changed.
/// - `animations`: the flights themselves, ready for `MotionPlayer.start`.
public struct WorkspaceSwitchMotion: Equatable, Sendable {
    public var prepositions: [WindowID: CGRect]
    public var animations: [WindowAnimation]

    public init(prepositions: [WindowID: CGRect] = [:], animations: [WindowAnimation] = []) {
        self.prepositions = prepositions
        self.animations = animations
    }
}

/// The frame straight below `frame`: same x and size, hanging past the
/// display's bottom edge with only the parking sliver inside. macOS cannot
/// put windows above the menu bar, so every workspace switch moves vertically
/// through the bottom edge, whichever way the workspace numbers go.
public func slideDownFrame(_ frame: CGRect, display: CGRect) -> CGRect {
    CGRect(
        x: frame.minX, y: display.minY - frame.height + parkingSliver,
        width: frame.width, height: frame.height
    )
}

/// MM-03: whether a switch may slide through `display`'s bottom edge: the
/// band straight below it (its width, one display height deep) touches no
/// other display. A display stacked above another one overlaps that band.
/// Edges that only touch (side by side) do not count.
public func canSlideBelow(_ display: CGRect, otherDisplays: [CGRect]) -> Bool {
    let band = CGRect(
        x: display.minX, y: display.minY - display.height, width: display.width, height: display.height
    )
    return !otherDisplays.contains { $0.intersects(band) }
}

/// Outgoing windows (`hidden`, the targets `planHiddenWindows` chose) drop
/// straight down from where they are; the final exact pass then writes the
/// true hidden corner while they are out of sight. Incoming windows that were
/// hidden rise from directly below their target; incoming windows already in
/// view (a retarget in flight) continue from their sampled frame, so nothing
/// snaps. Everything else follows `planMotion` (edge entries, scrolling).
/// MM-03: when a display lies below (`canSlideBelow` is false), nothing
/// moves through that band: windows coming from below and outgoing ones are
/// left to the final pass, which jumps them (no pre-position, no flight).
public func planWorkspaceSwitchMotion(
    current: [WindowID: CGRect],
    visible: [WindowID: CGRect],
    parked: [WindowID: ParkedTarget],
    hidden: [WindowID: ParkedTarget],
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect],
    duration: TimeInterval,
    easing: AnimationEasing = .easeInOut,
    tolerance: CGFloat = 1
) -> WorkspaceSwitchMotion {
    var result = WorkspaceSwitchMotion()
    let slides = canSlideBelow(display, otherDisplays: otherDisplays)
    var ordinary = visible
    for id in visible.keys.sorted() {
        guard let start = current[id], let target = visible[id],
              isBelowDisplay(start, display: display, tolerance: tolerance),
              !isOnScreen(start, viewport: viewport),
              isOnScreen(target, viewport: viewport)
        else {
            continue
        }
        ordinary.removeValue(forKey: id)
        guard slides else {
            continue
        }
        let launch = slideDownFrame(target, display: display)
        result.prepositions[id] = launch
        result.animations.append(
            WindowAnimation(id: id, from: launch, to: target, duration: duration, easing: easing)
        )
    }
    result.animations += planMotion(
        current: current, visible: ordinary, parked: parked, viewport: viewport,
        duration: duration, easing: easing, tolerance: tolerance
    )
    for id in hidden.keys.sorted() where slides {
        guard let start = current[id], isOnScreen(start, viewport: viewport) else {
            continue
        }
        let end = slideDownFrame(start, display: display)
        guard abs(start.minY - end.minY) > tolerance else {
            continue
        }
        result.animations.append(
            WindowAnimation(id: id, from: start, to: end, duration: duration, easing: easing)
        )
    }
    return result
}

private func isBelowDisplay(_ frame: CGRect, display: CGRect, tolerance: CGFloat) -> Bool {
    frame.maxY <= display.minY + parkingSliver + tolerance
}
