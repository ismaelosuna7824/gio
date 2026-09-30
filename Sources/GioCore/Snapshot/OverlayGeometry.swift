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
/// touches a display (parked to parked: nothing to draw). A parked window's
/// 1 pt sliver does not count: at least `minimumVisible` points must be
/// inside the display on both axes.
public func overlayDisplayIndex(
    from: CGRect, to: CGRect, displays: [CGRect], minimumVisible: CGFloat = 8
) -> Int? {
    func best(_ frame: CGRect) -> Int? {
        var result: (index: Int, area: CGFloat)?
        for (index, display) in displays.enumerated() {
            let overlap = display.intersection(frame)
            guard !overlap.isNull, overlap.width >= minimumVisible, overlap.height >= minimumVisible else {
                continue
            }
            let area = overlap.width * overlap.height
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

// MARK: flight deadline

/// The landing time of an overlay flight, owned by Gio instead of Core
/// Animation: CA completion fires at once for layers that are not attached to
/// a render context yet (seen live: 6-83 ms flights). The deadline is
/// `now + settle time of the spring`; a retarget extends it (never shortens)
/// and supersedes the previous timer token.
public struct FlightDeadline: Equatable, Sendable {
    public private(set) var deadline: TimeInterval?
    private var generation = 0

    public init() {}

    @discardableResult
    public mutating func begin(now: TimeInterval, settle: TimeInterval) -> (token: Int, deadline: TimeInterval) {
        deadline = nil
        return arm(now: now, settle: settle)
    }

    @discardableResult
    public mutating func retarget(now: TimeInterval, settle: TimeInterval) -> (token: Int, deadline: TimeInterval) {
        arm(now: now, settle: settle)
    }

    public mutating func abort() {
        generation += 1
        deadline = nil
    }

    public func isCurrent(_ token: Int) -> Bool {
        token == generation && deadline != nil
    }

    public func isDue(_ token: Int, now: TimeInterval) -> Bool {
        guard isCurrent(token), let deadline else {
            return false
        }
        return now >= deadline
    }

    /// True once, when `token` is current and due: the flight is over.
    public mutating func finish(_ token: Int, now: TimeInterval) -> Bool {
        guard isDue(token, now: now) else {
            return false
        }
        deadline = nil
        return true
    }

    private mutating func arm(now: TimeInterval, settle: TimeInterval) -> (token: Int, deadline: TimeInterval) {
        generation += 1
        let next = max(deadline ?? 0, now + max(settle, 0))
        deadline = next
        return (generation, next)
    }
}

/// Seconds a critically/under/over damped spring needs to travel `travel`
/// points from rest, capped like the Core Animation duration.
public func flightSettleTime(spring: SpringParameters, travel: Double) -> TimeInterval {
    min(spring.settleTime(axes: [(displacement: travel, velocity: 0)]), SpringParameters.maxDuration)
}

/// Largest movement of any edge/size component between two frames.
public func flightTravel(from: CGRect, to: CGRect) -> Double {
    Double(max(
        abs(to.minX - from.minX), abs(to.minY - from.minY),
        abs(to.width - from.width), abs(to.height - from.height)
    ))
}

/// Diagnostic: a flight shorter than 50 ms that moved a layer by more than
/// 1 pt means the animation did not run (the regression this deadline fixes).
public func flightTooShort(duration: TimeInterval, travel: Double) -> Bool {
    duration < 0.05 && travel > 1
}
