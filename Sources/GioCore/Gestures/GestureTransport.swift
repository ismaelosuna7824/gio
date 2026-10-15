import CoreGraphics
import Foundation

public let gestureOverlayKeepAlive: TimeInterval = 0.5

public enum GestureOverlayRefusal: String, Equatable, Sendable {
    case renderer = "renderer-ax"
    case noBackdrop = "no-backdrop"
    case cacheMiss = "cache-miss"
    case nothingToShow = "nothing-to-show"
    case overlayLost = "overlay-lost"
}

public enum GestureTransport: Equatable, Sendable {
    case overlay(layers: [WindowID])
    case accessibility(reason: GestureOverlayRefusal, missing: [WindowID])
}

public func planGestureTransport(
    windows: Set<WindowID>, rendererUsable: Bool, backdropReady: Bool, hasImage: (WindowID) -> Bool,
    undrawn: Set<WindowID> = []
) -> GestureTransport {
    guard rendererUsable else {
        return .accessibility(reason: .renderer, missing: [])
    }
    guard backdropReady else {
        return .accessibility(reason: .noBackdrop, missing: [])
    }
    let drawn = windows.subtracting(undrawn).sorted()
    let missing = drawn.filter { !hasImage($0) }
    guard missing.isEmpty else {
        return .accessibility(reason: .cacheMiss, missing: missing)
    }
    guard !drawn.isEmpty else {
        return .accessibility(reason: .nothingToShow, missing: [])
    }
    return .overlay(layers: drawn)
}

public func gestureTransportLine(_ transport: GestureTransport) -> String {
    switch transport {
    case .overlay(let layers):
        return "gesture scroll transport=overlay layers=\(layers.count)"
    case .accessibility(let reason, let missing):
        let counted = missing.isEmpty ? "" : " missing=\(missing.count)"
        return "gesture scroll transport=ax reason=\(reason.rawValue)\(counted)"
    }
}

public func gestureSettleVelocities(
    windows: Set<WindowID>, velocity: CGFloat, from starts: [WindowID: CGRect], to targets: [WindowID: CGRect]
) -> [WindowID: CGPoint] {
    var velocities: [WindowID: CGPoint] = [:]
    for id in windows {
        guard let start = starts[id], let target = targets[id],
              flightTravel(from: start, to: target) > Double(frameWriteTolerance)
        else {
            continue
        }
        velocities[id] = CGPoint(x: velocity, y: 0)
    }
    return velocities
}
