import Foundation

/// PA-06: what Gio has learned about how well each app takes size writes
/// during motion. Pure and keyed by an opaque string (the host uses the app
/// name, so the knowledge survives a relaunch within the session).
///
/// Every finished motion feeds the per-app write stats: an EWMA of the cost
/// of one frame write (ms) and of the fraction of frames the app could not
/// take. The app can animate its size when it is cheap, keeps up, and has not
/// clamped a size recently.
///
/// Unknown apps are conservative: no size animation until two usable motions
/// have been observed. There is no probe; position-only motion frames already
/// give a fair cost signal, and FI-03 (grow at the final pass) is the safe
/// default meanwhile.
public struct ResizeCapability: Equatable, Sendable {
    public static let maxCostMilliseconds = 4.0
    public static let maxDropRate = 0.1
    public static let smoothing = 0.4
    public static let minimumSamples = 2
    /// A motion needs at least this many writes+drops to say anything.
    public static let minimumFrames = 3
    /// Clean motions that must pass after a size clamp before growing again.
    public static let clampCooldownMotions = 5

    public struct Metrics: Equatable, Sendable {
        public var costMilliseconds: Double
        public var dropRate: Double
        public var samples: Int
        public var clampCooldown: Int
    }

    private var entries: [String: Metrics] = [:]

    public init() {}

    public func metrics(_ key: String) -> Metrics? { entries[key] }

    public func canAnimateSize(_ key: String) -> Bool {
        guard let entry = entries[key] else {
            return false
        }
        return entry.samples >= Self.minimumSamples && entry.clampCooldown == 0
            && entry.costMilliseconds <= Self.maxCostMilliseconds && entry.dropRate <= Self.maxDropRate
    }

    /// Fold one finished motion into the app's averages. True when the
    /// verdict (`canAnimateSize`) changed.
    @discardableResult
    public mutating func record(_ key: String, stats: MotionWriteStats) -> Bool {
        let frames = stats.count + stats.drops
        guard frames >= Self.minimumFrames, stats.count > 0 else {
            return false
        }
        let before = canAnimateSize(key)
        let cost = stats.sumMilliseconds / Double(stats.count)
        let drops = Double(stats.drops) / Double(frames)
        var entry = entries[key] ?? Metrics(costMilliseconds: cost, dropRate: drops, samples: 0, clampCooldown: 0)
        if entry.samples > 0 {
            entry.costMilliseconds += Self.smoothing * (cost - entry.costMilliseconds)
            entry.dropRate += Self.smoothing * (drops - entry.dropRate)
        }
        entry.samples += 1
        entry.clampCooldown = max(0, entry.clampCooldown - 1)
        entries[key] = entry
        return canAnimateSize(key) != before
    }

    /// The app clamped a size (a frame mismatch that taught a minimum): stop
    /// growing during flight for the next few motions. True when the verdict
    /// changed.
    @discardableResult
    public mutating func noteClamp(_ key: String) -> Bool {
        let before = canAnimateSize(key)
        var entry = entries[key] ?? Metrics(costMilliseconds: 0, dropRate: 0, samples: 0, clampCooldown: 0)
        entry.clampCooldown = Self.clampCooldownMotions
        entries[key] = entry
        return canAnimateSize(key) != before
    }
}
