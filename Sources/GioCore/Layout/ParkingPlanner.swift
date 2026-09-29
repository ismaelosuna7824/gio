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

    public init(frame: CGRect, edge: ParkEdge, display: CGRect) {
        self.frame = frame
        self.edge = edge
        self.display = display
    }
}

public struct ParkingPlan: Equatable, Sendable {
    public var visible: [WindowID: CGRect]
    public var parked: [WindowID: ParkedTarget]
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
public func planParking(
    frames: [WindowID: CGRect],
    viewport: CGRect,
    display: CGRect,
    otherDisplays: [CGRect]
) -> ParkingPlan {
    var plan = ParkingPlan(visible: [:], parked: [:])
    for (id, frame) in frames {
        if frame.intersects(viewport) {
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
    for edge in order {
        let rect = candidate(edge)
        if !otherDisplays.contains(where: { $0.intersects(rect) }) {
            return ParkedTarget(frame: rect, edge: edge, display: display)
        }
    }
    return ParkedTarget(frame: candidate(.corner), edge: .corner, display: display)
}
