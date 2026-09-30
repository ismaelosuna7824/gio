import CoreGraphics
import Foundation

/// NA-02: the default rise of a newly opened window, in points.
public let windowOpenDefaultOffset: CGFloat = 24

/// NA-02: where a newly opened window starts its entry. Its final size (one
/// size write, in the pre-position, like focused-grow at start) and its
/// target origin moved `offset` points down, so the spring only moves the
/// origin. The drop is at most a quarter of the window's height. It may hang
/// past the display's bottom edge (macOS only refuses the top, NC-07 relies
/// on it) but never onto a display below: then it stops at the edge.
public func windowOpenStartFrame(
    target: CGRect, display: CGRect, otherDisplays: [CGRect], offset: CGFloat
) -> CGRect {
    guard offset > 0, offset.isFinite else {
        return target
    }
    var start = target.offsetBy(dx: 0, dy: -min(offset, target.height / 4))
    if start.minY < display.minY {
        let strip = CGRect(
            x: start.minX, y: start.minY, width: start.width, height: display.minY - start.minY
        )
        if otherDisplays.contains(where: { $0.intersects(strip) }) {
            start.origin.y = min(target.minY, display.minY)
        }
    }
    return start
}

/// NA-02: which of the windows opened since the last pass enter from below,
/// and from where. Only tiled windows whose target is in view on this
/// display (not parked, more than a sliver inside the viewport): a window
/// that opens in a parked column or on a hidden workspace is simply placed.
public func planWindowOpenEntries(
    opening: Set<WindowID>,
    visible: [WindowID: CGRect],
    parked: Set<WindowID>,
    modes: [WindowID: WindowMode],
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect],
    offset: CGFloat
) -> [WindowID: CGRect] {
    var entries: [WindowID: CGRect] = [:]
    for id in opening where !parked.contains(id) && modes[id] == .tiled {
        guard let target = visible[id], isOnScreen(target, viewport: viewport) else {
            continue
        }
        entries[id] = windowOpenStartFrame(
            target: target, display: display, otherDisplays: otherDisplays, offset: offset
        )
    }
    return entries
}

/// NA-02: windows registered since the last layout pass. The next pass that
/// runs takes them: an animated one plans their entries, an instant one
/// (startup, permission regain, mouse, animations off) just places them.
public struct WindowOpenBook: Sendable {
    private var opened: Set<WindowID> = []

    public init() {}

    public var isEmpty: Bool { opened.isEmpty }

    public mutating func mark(_ id: WindowID) {
        opened.insert(id)
    }

    /// A purged window never enters.
    public mutating func forget(_ id: WindowID) {
        opened.remove(id)
    }

    public mutating func take(animating: Bool) -> Set<WindowID> {
        defer { opened = [] }
        return animating ? opened : []
    }
}
