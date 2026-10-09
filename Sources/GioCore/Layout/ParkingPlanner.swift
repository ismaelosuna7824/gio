import CoreGraphics
import Foundation

/// Where an off-viewport window was parked.
public enum ParkEdge: Equatable, Sendable {
    case left
    case right
    /// Both side edges touch another display: hang off the bottom-right.
    case corner
}

/// A parked window's desired frame plus what the reconciler needs to accept
/// a macOS-clamped landing (the display and the intended side).
public struct ParkedTarget: Equatable, Sendable {
    public let frame: CGRect
    public let edge: ParkEdge
    public let display: CGRect
    /// MM-04: the side the window leaves by touches another display, so it
    /// parks on the far side (or the corner). Its motion jumps instead of
    /// flying across the display (`ReflowPlan.jumps`).
    public let farSide: Bool

    public init(frame: CGRect, edge: ParkEdge, display: CGRect, farSide: Bool = false) {
        self.frame = frame
        self.edge = edge
        self.display = display
        self.farSide = farSide
    }
}

public struct ParkingPlan: Equatable, Sendable {
    public var visible: [WindowID: CGRect]
    public var parked: [WindowID: ParkedTarget]

    public init(visible: [WindowID: CGRect] = [:], parked: [WindowID: ParkedTarget] = [:]) {
        self.visible = visible
        self.parked = parked
    }
}

/// macOS refuses fully off-screen frames, so a parked window keeps this
/// many points inside its display (scrollable-tiler behavior, as in
/// AeroSpace/PaperWM).
public let parkingSliver: CGFloat = 1

/// Split laid-out frames into visible ones (unchanged, including columns
/// that only peek into the viewport) and parked ones. Everything is in
/// Cocoa space (y up), like layout and reconciler. `display` is the FULL
/// display frame (a Dock inset must not leave parked windows visible);
/// `viewport` is the usable area layout ran against.
///
/// MM-04: a column that peeks over an edge another display shares would
/// straddle both displays (macOS shows the rest of it on the neighbour and
/// may even move it there), so it parks like an off-viewport column. A peek
/// over a free edge stays (off every display, as on a single display).
/// `focusedColumn` (its windows) always stays visible, even a column wider
/// than its display (the niri rule: the focused column is shown).
public func planParking(
    frames: [WindowID: CGRect],
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect],
    focusedColumn: Set<WindowID> = []
) -> ParkingPlan {
    var plan = ParkingPlan(visible: [:], parked: [:])
    for (id, frame) in frames {
        let crossesDisplay = !focusedColumn.contains(id) && otherDisplays.contains { $0.intersects(frame) }
        if frame.intersects(viewport), !crossesDisplay {
            plan.visible[id] = frame
            continue
        }
        let preferLeft = frame.midX < viewport.midX
        plan.parked[id] = parkedTarget(
            for: frame, preferLeft: preferLeft, display: display, otherDisplays: otherDisplays
        )
    }
    return plan
}

/// Park every frame (a fullscreen window covers the display, so nothing
/// else may stay visible). Side preference follows each frame's position
/// against the viewport, exactly like `planParking`.
public func parkAll(
    frames: [WindowID: CGRect],
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect]
) -> [WindowID: ParkedTarget] {
    frames.mapValues {
        parkedTarget(
            for: $0, preferLeft: $0.midX < viewport.midX,
            display: display, otherDisplays: otherDisplays
        )
    }
}

private func parkedTarget(
    for frame: CGRect, preferLeft: Bool, display: CGRect, otherDisplays: [CGRect]
) -> ParkedTarget {
    func candidate(_ edge: ParkEdge) -> CGRect {
        switch edge {
        case .left:
            return CGRect(
                x: display.minX - frame.width + parkingSliver, y: frame.minY,
                width: frame.width, height: frame.height
            )
        case .right:
            return CGRect(
                x: display.maxX - parkingSliver, y: frame.minY,
                width: frame.width, height: frame.height
            )
        case .corner:
            return CGRect(
                x: display.maxX - parkingSliver,
                y: display.minY - frame.height + parkingSliver,
                width: frame.width, height: frame.height
            )
        }
    }
    let order: [ParkEdge] = preferLeft ? [.left, .right] : [.right, .left]
    for (rank, edge) in order.enumerated() {
        let rect = candidate(edge)
        if !otherDisplays.contains(where: { $0.intersects(rect) }) {
            return ParkedTarget(frame: rect, edge: edge, display: display, farSide: rank > 0)
        }
    }
    return ParkedTarget(frame: candidate(.corner), edge: .corner, display: display, farSide: true)
}
