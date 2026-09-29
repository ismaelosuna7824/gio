import CoreGraphics
import Foundation

/// PA-06 `[animations] resize`.
public enum ResizeMode: String, Equatable, Sendable {
    /// Grow during flight when the app keeps up (default).
    case adaptive
    /// Ignore the capability; still never overlap a neighbour.
    case always
    /// FI-03: every grow waits for the final pass.
    case never
}

/// Overlap larger than this on both axes counts as in the way (rounding to
/// whole points can make touching frames differ by a point).
private let overlapTolerance: CGFloat = 1
private let sampleCount = 19
/// Earliest grow starts tried, as fractions of the flight.
let growStartCandidates: [Double] = stride(from: 0.0, through: 0.9, by: 0.05).map { $0 }

func growsAtAll(_ animation: WindowAnimation) -> Bool {
    animation.duration > 0
        && (animation.to.width - animation.from.width > overlapTolerance
            || animation.to.height - animation.from.height > overlapTolerance)
}

/// The first candidate start (fraction of the flight) at which `animation`,
/// growing from there, never overlaps any of `others` at the sampled instants
/// (5%..95% of its own flight, neighbours sampled at the same absolute time
/// through their own `motionFrame`). Nil when no candidate works.
func delayedGrowStart(
    for animation: WindowAnimation, among others: [WindowAnimation],
    candidates: [Double] = growStartCandidates
) -> Double? {
    let neighbours = others.filter { $0.id != animation.id }
    for start in candidates {
        var trial = animation
        trial.sizeSchedule = start == 0 ? .fromStart : .from(start)
        if isClear(trial, of: neighbours) {
            return start
        }
    }
    return nil
}

private func isClear(_ animation: WindowAnimation, of neighbours: [WindowAnimation]) -> Bool {
    for step in 1...sampleCount {
        let elapsed = animation.duration * Double(step) / Double(sampleCount + 1)
        let frame = animation.motionFrame(at: elapsed)
        for other in neighbours {
            let overlap = frame.intersection(other.motionFrame(at: elapsed))
            if !overlap.isNull && overlap.width > overlapTolerance && overlap.height > overlapTolerance {
                return false
            }
        }
    }
    return true
}

/// Decide, per growing window, whether its size may interpolate during the
/// flight (PA-06). Shrinks are untouched (they stay on the first frame). A
/// grow needs its app in `capablePids` (unless mode is `always`) and a
/// geometric proof of no overlap with the other animations' planned motion
/// frames; when a neighbour is in the way early, the grow starts later
/// (delayed grow) as long as it still lands exactly at the end. Windows are
/// decided in id order against the already-decided schedules, so a pair is
/// checked with the final frames of whoever was decided first. Windows that do
/// not animate are not obstacles here: the layout never overlaps them.
public func planSizeSchedules(
    _ animations: [WindowAnimation], mode: ResizeMode, capablePids: Set<pid_t>
) -> [WindowAnimation] {
    guard mode != .never else {
        return animations
    }
    var result = animations
    let order = animations.indices.sorted { animations[$0].id < animations[$1].id }
    for index in order {
        let animation = result[index]
        guard growsAtAll(animation), mode == .always || capablePids.contains(animation.id.pid),
              let start = delayedGrowStart(for: animation, among: result)
        else {
            continue
        }
        result[index].sizeSchedule = start == 0 ? .fromStart : .from(start)
    }
    return result
}
