import CoreGraphics
import Foundation

/// One display as the restore planner sees it (Cocoa space, y up): the full
/// frame decides whether a window is on screen at all, the visible frame
/// (menu bar and Dock excluded) is where restored windows land.
public struct RestoreDisplay: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Distance between cascaded windows, in points.
public let restoreCascadeStep: CGFloat = 32
/// Cascade steps before the offset wraps back to the corner.
private let restoreCascadeSlots = 8

/// Frames that bring parked or otherwise off-screen windows back fully inside
/// a display's visible frame. Windows already fully on some display are
/// absent from the result. Size is kept (shrunk only when larger than the
/// visible frame); windows landing on the same display cascade from its
/// top-left corner in `WindowID` order so none sits exactly on another.
public func planRestore(
    windows: [WindowID: CGRect],
    displays: [RestoreDisplay]
) -> [WindowID: CGRect] {
    guard !displays.isEmpty else {
        return [:]
    }
    var plan: [WindowID: CGRect] = [:]
    var cascadeIndex: [Int: Int] = [:]
    for id in windows.keys.sorted() {
        let frame = windows[id]!
        if displays.contains(where: { isInside(frame, $0.frame) }) {
            continue
        }
        let home = homeDisplay(for: frame, displays: displays)
        let visible = displays[home].visibleFrame
        let slot = (cascadeIndex[home] ?? 0) % restoreCascadeSlots
        cascadeIndex[home, default: 0] += 1
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let offset = restoreCascadeStep * CGFloat(slot)
        let x = min(max(visible.minX + offset, visible.minX), visible.maxX - width)
        let y = min(max(visible.maxY - height - offset, visible.minY), visible.maxY - height)
        plan[id] = CGRect(x: x, y: y, width: width, height: height)
    }
    return plan
}

private func isInside(_ frame: CGRect, _ container: CGRect) -> Bool {
    frame.minX >= container.minX - 1 && frame.maxX <= container.maxX + 1
        && frame.minY >= container.minY - 1 && frame.maxY <= container.maxY + 1
}

/// The display sharing the most area with the window, else the nearest one.
private func homeDisplay(for frame: CGRect, displays: [RestoreDisplay]) -> Int {
    var best = 0
    var bestArea: CGFloat = -1
    for (index, display) in displays.enumerated() {
        let overlap = frame.intersection(display.frame)
        let area = overlap.isNull ? 0 : overlap.width * overlap.height
        if area > bestArea {
            best = index
            bestArea = area
        }
    }
    if bestArea > 0 {
        return best
    }
    var nearest = 0
    var nearestDistance = CGFloat.greatestFiniteMagnitude
    for (index, display) in displays.enumerated() {
        let dx = frame.midX - display.frame.midX
        let dy = frame.midY - display.frame.midY
        let distance = dx * dx + dy * dy
        if distance < nearestDistance {
            nearest = index
            nearestDistance = distance
        }
    }
    return nearest
}
