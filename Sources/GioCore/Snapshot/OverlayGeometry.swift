import CoreGraphics
import Foundation

// SM-03: pure math behind the GPU snapshot overlay (GioUI `SnapshotOverlay`).
// Everything the AppKit/Core Animation code decides lives here so it is
// tested without a screen.

/// Layer geometry in the overlay's local space: `position` is the layer's
/// center (default anchor point), `bounds` starts at the origin.
public struct LayerGeometry: Equatable, Sendable {
    public var position: CGPoint
    public var bounds: CGRect

    public init(position: CGPoint, bounds: CGRect) {
        self.position = position
        self.bounds = bounds
    }
}

/// Cocoa global frame (bottom-left origin) to overlay-local layer geometry.
/// `flipped` is true when the overlay's root layer measures y from the top
/// (`isGeometryFlipped`); the overlay uses an unflipped view, so it passes
/// false, but the conversion is explicit and covered both ways.
public func overlayLayerGeometry(frame: CGRect, in display: CGRect, flipped: Bool) -> LayerGeometry {
    let localX = frame.minX - display.minX
    let localBottom = frame.minY - display.minY
    let localY = flipped ? display.height - localBottom - frame.height : localBottom
    return LayerGeometry(
        position: CGPoint(x: localX + frame.width / 2, y: localY + frame.height / 2),
        bounds: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
    )
}

/// `CASpringAnimation` parameters for a Gio spring: mass 1, the same
/// stiffness, damping `2 ζ sqrt(k)` (the equation `SpringParameters` solves).
public struct OverlaySpring: Equatable, Sendable {
    public let mass: Double
    public let stiffness: Double
    public let damping: Double
}

public func overlaySpring(_ spring: SpringParameters) -> OverlaySpring {
    OverlaySpring(
        mass: 1, stiffness: spring.stiffness,
        damping: 2 * spring.dampingRatio * spring.stiffness.squareRoot()
    )
}

/// Where a retargeted layer starts: the value on screen right now (the
/// presentation layer), else its model value. Velocity is not carried over.
public func retargetStart(presentation: LayerGeometry?, model: LayerGeometry) -> LayerGeometry {
    presentation ?? model
}

public struct OverlayDiff: Equatable, Sendable {
    public var added: [WindowID]
    public var removed: [WindowID]
    public var retargeted: [WindowID]

    public init(added: [WindowID], removed: [WindowID], retargeted: [WindowID]) {
        self.added = added
        self.removed = removed
        self.retargeted = retargeted
    }
}

/// Layers to create, drop and retarget when the wanted set changes.
public func diffOverlayItems(existing: Set<WindowID>, next: Set<WindowID>) -> OverlayDiff {
    OverlayDiff(
        added: next.subtracting(existing).sorted(),
        removed: existing.subtracting(next).sorted(),
        retargeted: existing.intersection(next).sorted()
    )
}

/// Index of the display whose overlay carries a layer: the one holding most
/// of the target frame, else most of the start frame, nil when neither
/// touches a display (parked to parked: nothing to draw).
public func overlayDisplayIndex(from: CGRect, to: CGRect, displays: [CGRect]) -> Int? {
    func best(_ frame: CGRect) -> Int? {
        var result: (index: Int, area: CGFloat)?
        for (index, display) in displays.enumerated() {
            let overlap = display.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (result?.area ?? 0) {
                result = (index, area)
            }
        }
        return result?.index
    }
    return best(to) ?? best(from)
}

/// Bound for one overlay flight: it may not outlive `limit` seconds since it
/// was armed (begin or retarget). A new arm supersedes older tokens.
public struct FlightWatchdog: Equatable, Sendable {
    public static let defaultLimit: TimeInterval = 1.5

    private let limit: TimeInterval
    private var generation = 0
    private var armedAt: TimeInterval?

    public init(limit: TimeInterval = FlightWatchdog.defaultLimit) {
        self.limit = limit
    }

    public mutating func arm(at now: TimeInterval) -> Int {
        generation += 1
        armedAt = now
        return generation
    }

    public mutating func disarm() {
        generation += 1
        armedAt = nil
    }

    public func isCurrent(_ token: Int) -> Bool {
        token == generation && armedAt != nil
    }

    public func isExpired(_ token: Int, now: TimeInterval) -> Bool {
        guard isCurrent(token), let armedAt else {
            return false
        }
        return now - armedAt >= limit
    }
}
