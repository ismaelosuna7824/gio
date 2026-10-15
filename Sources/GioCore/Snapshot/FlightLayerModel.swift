import CoreGraphics
import Foundation

public struct FlightLayerModel: Sendable {
    private struct Layer: Sendable {
        var track: FlightTrack
        var startedAt: TimeInterval?
    }

    private var layers: [WindowID: Layer] = [:]
    private var spring: SpringParameters

    public init(spring: SpringParameters) {
        self.spring = spring
    }

    public mutating func reset(spring: SpringParameters) {
        self.spring = spring
        layers = [:]
    }

    public mutating func removeAll() {
        layers = [:]
    }

    public mutating func add(_ id: WindowID, from: CGRect, to: CGRect, velocity: CGPoint, at now: TimeInterval) {
        let flying = layers.values.contains { $0.startedAt != nil }
        let track = FlightTrack(
            start: Self.geometry(from), end: Self.geometry(to),
            velocity: overlayLayerVelocity(origin: velocity, flipped: false)
        )
        layers[id] = Layer(track: track, startedAt: flying ? now : nil)
    }

    public mutating func fly(at now: TimeInterval) {
        for id in layers.keys where layers[id]?.startedAt == nil {
            layers[id]?.startedAt = now
        }
    }

    public mutating func retarget(
        _ targets: [WindowID: CGRect], velocities: [WindowID: CGPoint], at now: TimeInterval
    ) {
        for (id, frame) in targets {
            guard var layer = layers[id] else {
                continue
            }
            let end = Self.geometry(frame)
            if let startedAt = layer.startedAt {
                layer.track = layer.track.retargeted(to: end, at: now - startedAt, spring: spring)
                layer.startedAt = now
            } else {
                layer.track.end = end
                if let velocity = velocities[id] {
                    layer.track.velocity = overlayLayerVelocity(origin: velocity, flipped: false)
                }
            }
            layers[id] = layer
        }
    }

    public mutating func track(_ frames: [WindowID: CGRect]) {
        for (id, frame) in frames where layers[id]?.startedAt == nil {
            layers[id]?.track.start = Self.geometry(frame)
        }
    }

    public func frames(at now: TimeInterval) -> [WindowID: CGRect] {
        layers.mapValues { layer in
            guard let startedAt = layer.startedAt else {
                return Self.frame(layer.track.start)
            }
            return Self.frame(layer.track.state(at: now - startedAt, spring: spring).geometry)
        }
    }

    private static func geometry(_ frame: CGRect) -> LayerGeometry {
        overlayLayerGeometry(frame: frame, in: .zero, flipped: false)
    }

    private static func frame(_ geometry: LayerGeometry) -> CGRect {
        let size = geometry.bounds.size
        return CGRect(
            x: geometry.position.x - size.width / 2, y: geometry.position.y - size.height / 2,
            width: size.width, height: size.height
        )
    }
}
