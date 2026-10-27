import CoreGraphics
import Foundation

// SM-03/SM-08: pure math behind the GPU snapshot overlay (GioUI
// `SnapshotOverlay`). Everything the AppKit/Core Animation code decides lives
// here so it is tested without a screen.

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

// MARK: panel area (SM-18)

/// The part of a display one overlay panel covers: the usable frame (the one
/// the layout uses, menu bar and Dock excluded), so the live menu bar and
/// Dock, which are transparent and draw above the panel, never show a stale
/// captured copy through themselves. Layers, holes and the mask are local to
/// `panelFrame` (pass it as the `in:` frame below); the backdrop, a capture
/// of the whole display, is cropped to it with `backdropContentsRect`.
public struct OverlayArea: Equatable, Sendable {
    public let display: CGRect
    /// The usable frame clamped to the display; the whole display when the
    /// usable frame does not overlap it (auto-hide menu bar and Dock: equal).
    public let panelFrame: CGRect

    public init(display: CGRect, usable: CGRect) {
        self.display = display
        let clamped = display.intersection(usable)
        panelFrame = clamped.isNull || clamped.width <= 0 || clamped.height <= 0 ? display : clamped
    }

    /// `contentsRect` (unit space of the display-sized capture) showing just
    /// the panel's part, its edges snapped to the capture's pixel grid
    /// (`scale` pixels per point). `flipped`: unit y measured from the top
    /// (the layer's contents are flipped) instead of from the bottom.
    public func backdropContentsRect(scale: CGFloat, flipped: Bool) -> CGRect {
        guard display.width > 0, display.height > 0, scale > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let width = display.width * scale
        let height = display.height * scale
        let left = ((panelFrame.minX - display.minX) * scale).rounded()
        let right = ((panelFrame.maxX - display.minX) * scale).rounded()
        let low = flipped ? display.maxY - panelFrame.maxY : panelFrame.minY - display.minY
        let high = flipped ? display.maxY - panelFrame.minY : panelFrame.maxY - display.minY
        let bottom = (low * scale).rounded()
        let top = (high * scale).rounded()
        return CGRect(x: left / width, y: bottom / height, width: (right - left) / width, height: (top - bottom) / height)
    }
}

/// Cocoa global frame (bottom-left origin) to overlay-local layer geometry;
/// `display` is the overlay's frame (SM-18: `OverlayArea.panelFrame`).
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

/// Corner radius of a window layer: the one macOS gives windows, shared
/// with the live ring and dim so the hand-off draws the same shape.
public let overlayWindowCornerRadius: CGFloat = focusRingWindowCornerRadius

/// Velocity of a layer's geometry, points per second.
public struct LayerVelocity: Equatable, Sendable {
    public var position: CGVector
    public var size: CGSize

    public static let zero = LayerVelocity(position: .zero, size: .zero)

    public init(position: CGVector, size: CGSize) {
        self.position = position
        self.size = size
    }
}

public func overlayLayerVelocity(origin velocity: CGPoint, flipped: Bool) -> LayerVelocity {
    let vertical = flipped ? -velocity.y : velocity.y
    return LayerVelocity(position: CGVector(dx: velocity.x, dy: vertical), size: .zero)
}

/// One layer's flight: where it started, where it lands and how fast it was
/// going when this flight (re)started. Each axis (x, y, width, height) is
/// Gio's own spring (`SpringParameters.state`), the model the AX renderer
/// animates with, so the overlay moves exactly like the real windows would.
public struct FlightTrack: Equatable, Sendable {
    public var start: LayerGeometry
    public var end: LayerGeometry
    public var velocity: LayerVelocity

    public init(start: LayerGeometry, end: LayerGeometry, velocity: LayerVelocity = .zero) {
        self.start = start
        self.end = end
        self.velocity = velocity
    }

    /// Displacement and velocity of every axis relative to the target.
    private var axes: [(displacement: Double, velocity: Double)] {
        [
            (Double(start.position.x - end.position.x), Double(velocity.position.dx)),
            (Double(start.position.y - end.position.y), Double(velocity.position.dy)),
            (Double(start.bounds.width - end.bounds.width), Double(velocity.size.width)),
            (Double(start.bounds.height - end.bounds.height), Double(velocity.size.height)),
        ]
    }

    /// Geometry and velocity `elapsed` seconds into the flight.
    public func state(at elapsed: TimeInterval, spring: SpringParameters) -> (geometry: LayerGeometry, velocity: LayerVelocity) {
        let samples = axes.map { spring.state(displacement: $0.displacement, velocity: $0.velocity, at: elapsed) }
        let geometry = LayerGeometry(
            position: CGPoint(x: end.position.x + samples[0].displacement, y: end.position.y + samples[1].displacement),
            bounds: CGRect(
                x: 0, y: 0, width: end.bounds.width + samples[2].displacement,
                height: end.bounds.height + samples[3].displacement
            )
        )
        let velocity = LayerVelocity(
            position: CGVector(dx: samples[0].velocity, dy: samples[1].velocity),
            size: CGSize(width: samples[2].velocity, height: samples[3].velocity)
        )
        return (geometry, velocity)
    }

    /// A new flight towards `end` from where this one is `elapsed` seconds
    /// in, carrying its velocity: a retarget mid-air does not stutter.
    public func retargeted(to end: LayerGeometry, at elapsed: TimeInterval, spring: SpringParameters) -> FlightTrack {
        let current = state(at: elapsed, spring: spring)
        return FlightTrack(start: current.geometry, end: end, velocity: current.velocity)
    }

    /// Seconds until every axis is at rest, capped like the AX motion.
    public func settleTime(spring: SpringParameters) -> TimeInterval {
        min(spring.settleTime(axes: axes), SpringParameters.maxDuration)
    }

    /// Largest movement of any edge/size component.
    public var travel: Double {
        flightTravel(
            from: CGRect(origin: CGPoint(x: start.position.x - start.bounds.width / 2, y: start.position.y - start.bounds.height / 2), size: start.bounds.size),
            to: CGRect(origin: CGPoint(x: end.position.x - end.bounds.width / 2, y: end.position.y - end.bounds.height / 2), size: end.bounds.size)
        )
    }
}

/// A track sampled for `CAKeyframeAnimation`: `times` are fractions of
/// `duration`, one sample per display refresh at `rate` Hz, the last one
/// exactly the end. The render server interpolates between samples; Gio
/// does no per-frame work during the flight.
public struct FlightKeyframes: Equatable, Sendable {
    public var duration: TimeInterval
    public var times: [Double]
    public var geometries: [LayerGeometry]
}

public func flightKeyframes(track: FlightTrack, spring: SpringParameters, rate: Double = 120) -> FlightKeyframes {
    let duration = track.settleTime(spring: spring)
    let count = max(Int((duration * rate).rounded(.up)), 1)
    var times: [Double] = []
    var geometries: [LayerGeometry] = []
    times.reserveCapacity(count + 1)
    geometries.reserveCapacity(count + 1)
    for index in 0...count {
        let fraction = Double(index) / Double(count)
        times.append(fraction)
        geometries.append(index == count ? track.end : track.state(at: fraction * duration, spring: spring).geometry)
    }
    return FlightKeyframes(duration: duration, times: times, geometries: geometries)
}

// MARK: backdrop holes (SM-16)

/// The holes (Cocoa global frames) that touch `display` (the overlay's
/// frame, SM-18: `OverlayArea.panelFrame`), in the overlay's
/// local space: same origin and flip as `overlayLayerGeometry`.
public func overlayBackdropHoles(_ holes: [CGRect], in display: CGRect, flipped: Bool) -> [CGRect] {
    holes.compactMap { hole in
        let overlap = display.intersection(hole)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
            return nil
        }
        let geometry = overlayLayerGeometry(frame: hole, in: display, flipped: flipped)
        return CGRect(
            x: geometry.position.x - hole.width / 2, y: geometry.position.y - hole.height / 2,
            width: hole.width, height: hole.height
        )
    }
}

/// Mask of the backdrop layer: the whole overlay frame minus the holes, rounded
/// like the window layers, filled even-odd. The holes are merged first, so
/// overlapping holes stay open. Nil when no hole touches the display (the
/// backdrop needs no mask).
public func overlayBackdropMask(holes: [CGRect], in display: CGRect, flipped: Bool) -> CGPath? {
    let local = overlayBackdropHoles(holes, in: display, flipped: flipped)
    guard !local.isEmpty else {
        return nil
    }
    let shapes = local.map { rect in
        let radius = min(overlayWindowCornerRadius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    let merged = shapes.dropFirst().reduce(shapes[0]) { $0.union($1, using: .winding) }
    let mask = CGMutablePath()
    mask.addRect(CGRect(origin: .zero, size: display.size))
    mask.addPath(merged)
    return mask
}

/// WP-04: the holes one flight cuts, sorted by window: every hole in the
/// backdrop (`backdrop`), the entry holes (windows opening in this pass) in
/// the image layers as well (`images`). Each set is masked with
/// `overlayBackdropMask`.
public struct OverlayHoles: Equatable, Sendable {
    public let backdrop: [CGRect]
    public let images: [CGRect]

    public init(holes: [WindowID: CGRect] = [:], entries: Set<WindowID> = []) {
        let ids = holes.keys.sorted()
        backdrop = ids.map { holes[$0]! }
        images = ids.filter(entries.contains).map { holes[$0]! }
    }
}

// MARK: shadow, ring and dim

/// The shadow each window layer casts, in the layer's (y-up) space: offset
/// down. Real windows cast shadows into the gaps; without one the gaps
/// brighten when the overlay goes up and darken when it comes down.
public struct OverlayShadow: Equatable, Sendable {
    public var offset: CGSize
    public var radius: CGFloat
    public var opacity: Float
}

/// Between macOS's heavy key-window shadow and the lighter one of the other
/// windows (most tiles are not key): 10 pt down, 22 pt blur, 38 %. Chosen by
/// eye against Sonoma windows; the live match is checked on screen (SM-08).
public let overlayWindowShadow = OverlayShadow(offset: CGSize(width: 0, height: -10), radius: 22, opacity: 0.38)

/// Precomputed shadow outline (no per-frame offscreen pass): the window's
/// rounded rect.
public func overlayShadowPath(bounds: CGRect, cornerRadius: CGFloat) -> CGPath {
    CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

/// The ring layer around a window layer: the same center, the bounds outset
/// by the ring width, with a border of that width inside them, so the inner
/// edge sits on the window edge like the live ring (`FocusRingGeometry`).
public func overlayRingGeometry(window: LayerGeometry, width: CGFloat) -> LayerGeometry {
    LayerGeometry(
        position: window.position,
        bounds: CGRect(x: 0, y: 0, width: window.bounds.width + 2 * width, height: window.bounds.height + 2 * width)
    )
}

/// Outer radius of the ring layer; the inner edge keeps the window's radius.
public func overlayRingCornerRadius(width: CGFloat) -> CGFloat {
    overlayWindowCornerRadius + width
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
/// was armed (begin or retarget). A new arm supersedes older tokens. SM-14:
/// an arm may carry its own limit (the hand-off hold after the deadline,
/// `SnapshotHandoff.watchdogLimit`); the next plain arm uses `limit` again.
public struct FlightWatchdog: Equatable, Sendable {
    public static let defaultLimit: TimeInterval = 1.5

    private let limit: TimeInterval
    private var generation = 0
    private var armedAt: TimeInterval?
    private var armedLimit: TimeInterval

    public init(limit: TimeInterval = FlightWatchdog.defaultLimit) {
        self.limit = limit
        armedLimit = limit
    }

    public mutating func arm(at now: TimeInterval, limit: TimeInterval? = nil) -> Int {
        generation += 1
        armedAt = now
        armedLimit = limit ?? self.limit
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
        return now - armedAt >= armedLimit
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
