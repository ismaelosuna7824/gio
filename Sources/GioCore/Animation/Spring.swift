import Foundation

/// NF-04: a mass-1 damped spring (Niri's model: `damping-ratio`, `stiffness`,
/// `epsilon`). The motion of one axis is solved analytically, so it is
/// sampled by elapsed time with no integration error and no accumulated
/// state, exactly like the easing curves it replaces.
///
/// The equation of motion is `x'' = -k x - c x'` on the displacement `x`
/// from the target, with `c = 2 ζ sqrt(k)`. Under (ζ < 1), critically
/// (ζ = 1) and over damped (ζ > 1) cases have their own closed form; a
/// critically damped spring never overshoots when it starts at rest.
public struct SpringParameters: Equatable, Sendable {
    public static let dampingRatioRange = 0.2...3.0
    public static let stiffnessRange = 100.0...3000.0
    /// Hard cap on one flight, however soft the spring.
    public static let maxDuration: TimeInterval = 1
    /// Never chase a residual smaller than this many points: motion writes
    /// are rounded to whole points, so a half point is invisible (PA-03).
    public static let minimumThreshold = 0.5
    /// Niri's defaults for view movement.
    public static let niri = SpringParameters(dampingRatio: 1.0, stiffness: 800, epsilon: 0.0001)

    public var dampingRatio: Double
    public var stiffness: Double
    /// Rest threshold as a fraction of the travel distance (Niri: unit
    /// progress). Scaled to points per flight, floored at `minimumThreshold`.
    public var epsilon: Double

    public init(dampingRatio: Double, stiffness: Double, epsilon: Double) {
        self.dampingRatio = dampingRatio
        self.stiffness = stiffness
        self.epsilon = epsilon
    }

    /// Displacement and velocity `t` seconds after starting from
    /// `displacement` with `velocity` (both relative to the target).
    public func state(
        displacement d0: Double, velocity v0: Double, at t: Double
    ) -> (displacement: Double, velocity: Double) {
        guard t > 0, t.isFinite else {
            return (d0, v0)
        }
        let omega = stiffness.squareRoot()
        let zeta = dampingRatio
        if abs(zeta - 1) < 1e-9 {
            let a = d0
            let b = v0 + omega * d0
            let decay = exp(-omega * t)
            return (decay * (a + b * t), decay * (b - omega * (a + b * t)))
        }
        if zeta < 1 {
            let decayRate = zeta * omega
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let b = (v0 + decayRate * d0) / damped
            let decay = exp(-decayRate * t)
            let cosine = cos(damped * t), sine = sin(damped * t)
            let position = d0 * cosine + b * sine
            let slope = -d0 * damped * sine + b * damped * cosine
            return (decay * position, decay * (slope - decayRate * position))
        }
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
        let c1 = (v0 - r2 * d0) / (r1 - r2)
        let c2 = d0 - c1
        let e1 = exp(r1 * t), e2 = exp(r2 * t)
        return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
    }

    /// Seconds until every listed axis is at rest (displacement and
    /// velocity below the point threshold), capped at `maxDuration`.
    /// A velocity counts as rest when it moves less than the threshold
    /// within one 60 Hz frame.
    public func settleTime(axes: [(displacement: Double, velocity: Double)]) -> TimeInterval {
        let scale = axes.map { abs($0.displacement) }.max() ?? 0
        let threshold = max(epsilon * scale, Self.minimumThreshold)
        let velocityThreshold = threshold * 60
        let step = 0.004
        var lastActive = 0.0
        var t = 0.0
        while t < Self.maxDuration {
            for axis in axes {
                let sample = state(displacement: axis.displacement, velocity: axis.velocity, at: t)
                if abs(sample.displacement) > threshold || abs(sample.velocity) > velocityThreshold {
                    lastActive = t
                }
            }
            t += step
        }
        if lastActive >= Self.maxDuration - 2 * step {
            return Self.maxDuration
        }
        return max(lastActive + step, 1.0 / 60)
    }
}
