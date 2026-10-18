import CoreGraphics
import Foundation

/// WP-05: an opening window's pop under the snapshot renderer: its image
/// rises from its NA-02 entry start to its target while it fades in, timed
/// by the resolved window-open animation (its spring, or ease-out over its
/// duration).
public struct WindowOpenPop: Equatable, Sendable {
    public let id: WindowID
    public let motion: WindowAnimation

    public init(id: WindowID, from: CGRect, to: CGRect, animation: ResolvedAnimation) {
        self.id = id
        switch animation.curve {
        case .spring:
            motion = WindowAnimation(id: id, from: from, to: to, spring: animation.spring)
        case .easeOut:
            motion = WindowAnimation(id: id, from: from, to: to, duration: animation.duration, easing: .easeOut)
        }
    }

    public var from: CGRect { motion.from }
    public var to: CGRect { motion.to }
    public var duration: TimeInterval { motion.duration }

    public func frame(at elapsed: TimeInterval) -> CGRect {
        motion.frame(at: elapsed)
    }

    /// The fade follows the rise: transparent at the start, opaque once it
    /// arrived (a spring's overshoot reads as arrived).
    public func opacity(at elapsed: TimeInterval) -> Double {
        motion.normalizedProgress(at: elapsed)
    }

    /// The overlay watchdog while it pops: never shorter than a flight's.
    public var watchdogLimit: TimeInterval {
        max(FlightWatchdog.defaultLimit, duration + SnapshotHandoff.watchdogMargin)
    }
}

/// WP-05: a pop sampled for `CAKeyframeAnimation`, like `flightKeyframes`:
/// the geometry track and the opacity at each sample.
public struct WindowOpenPopKeyframes: Equatable, Sendable {
    public var flight: FlightKeyframes
    public var opacities: [Double]
}

/// `display` is the overlay's frame (`OverlayArea.panelFrame`); one sample
/// per display refresh at `rate` Hz, the last one exactly the target, opaque.
public func windowOpenPopKeyframes(
    _ pop: WindowOpenPop, in display: CGRect, flipped: Bool, rate: Double = 120
) -> WindowOpenPopKeyframes {
    let duration = pop.duration
    let count = max(Int((duration * rate).rounded(.up)), 1)
    var times: [Double] = []
    var geometries: [LayerGeometry] = []
    var opacities: [Double] = []
    times.reserveCapacity(count + 1)
    geometries.reserveCapacity(count + 1)
    opacities.reserveCapacity(count + 1)
    for index in 0...count {
        let fraction = Double(index) / Double(count)
        let last = index == count
        let frame = last ? pop.to : pop.frame(at: fraction * duration)
        times.append(fraction)
        geometries.append(overlayLayerGeometry(frame: frame, in: display, flipped: flipped))
        opacities.append(last ? 1 : pop.opacity(at: fraction * duration))
    }
    return WindowOpenPopKeyframes(
        flight: FlightKeyframes(duration: duration, times: times, geometries: geometries), opacities: opacities
    )
}

/// WP-05: the windows of a pass that stay covered under the snapshot
/// overlay until they redrew at their target, then pop in: each one's
/// NA-02 entry start and the resolved window-open animation.
public struct WindowOpenPopPlan: Equatable, Sendable {
    public let starts: [WindowID: CGRect]
    public let animation: ResolvedAnimation

    public init(starts: [WindowID: CGRect], animation: ResolvedAnimation) {
        self.starts = starts
        self.animation = animation
    }

    public var windows: Set<WindowID> { Set(starts.keys) }

    public func pop(_ id: WindowID, to target: CGRect) -> WindowOpenPop? {
        starts[id].map { WindowOpenPop(id: id, from: $0, to: target, animation: animation) }
    }
}

/// WP-05: the pop plan of a pass: its NA-02 entries with their start frames
/// (`prepositions`), nil when there is none or the window-open animation is
/// off (an entry is then shown through its hole, WP-04).
public func planWindowOpenPops(
    entries: Set<WindowID>, prepositions: [WindowID: CGRect], animation: ResolvedAnimation
) -> WindowOpenPopPlan? {
    guard animation.isActive else {
        return nil
    }
    let starts = prepositions.filter { entries.contains($0.key) }
    guard !starts.isEmpty else {
        return nil
    }
    return WindowOpenPopPlan(starts: starts, animation: animation)
}

/// WP-05: why an opening window was revealed without its pop.
public enum WindowOpenRevealReason: String, Equatable, Sendable {
    /// The wait ended on a read not yet at its target size or partly painted.
    case timeout
    /// The wait ended on a blank read.
    case blank
    /// The wait ended without a read (no match, failed or still out).
    case noCapture
    /// A retarget moved it (or took it out of view) before it popped in.
    case retarget
    /// The overlay came down (abort, end, failed prime, gesture).
    case abort
}

/// WP-05: the covered opening windows of one flight. Each waits (no hole)
/// from `cover` until a capture at its target reads fresh (`record`:
/// `.pop`), then pops until `popped`. A read that is not fresh is retried
/// every `retryInterval` while the wait lasts; at `maxWait` after `cover`
/// (`expire`) a window still waiting is revealed without the pop. Tokens
/// never repeat, so a timer or an answer of an earlier cover is dropped.
public struct WindowOpenPopBook: Equatable, Sendable {
    /// Longest wait for the redraw, from the pass that opened the window.
    /// Live, Notes read painted ~160 ms after its write; the overlay of a
    /// mid-strip flight is up ~350 ms anyway.
    public static let maxWait: TimeInterval = 0.4
    /// From the write under the overlay to the first capture: a native app
    /// has usually redrawn by then.
    public static let firstCaptureDelay: TimeInterval = 0.05
    public static let retryInterval: TimeInterval = SnapshotFreshTracker.retryInterval

    public enum Step: Equatable, Sendable {
        /// The read shows the window redrawn: pop it in (`waited` since its cover).
        case pop(WindowOpenPop, waited: TimeInterval)
        case retry(after: TimeInterval)
        /// No time left for another capture: the wait expires on its own.
        case wait
    }

    private struct Entry: Equatable, Sendable {
        let token: Int
        let pop: WindowOpenPop
        let coveredAt: TimeInterval
        var popping = false
        var last: SnapshotFreshVerdict?
    }

    private var counter = 0
    private var entries: [WindowID: Entry] = [:]

    public init() {}

    /// Waiting or popping: no hole, the backdrop covers the slot.
    public var covered: Set<WindowID> { Set(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }

    public func pop(of id: WindowID) -> WindowOpenPop? {
        entries[id]?.pop
    }

    /// The token of each window still waiting for its redraw.
    public var waitingTokens: [WindowID: Int] {
        entries.filter { !$0.value.popping }.mapValues(\.token)
    }

    public func isWaiting(_ id: WindowID, token: Int) -> Bool {
        guard let entry = entries[id] else {
            return false
        }
        return entry.token == token && !entry.popping
    }

    /// Cover `pop.id` from `now`: the token its timers and captures carry.
    public mutating func cover(_ pop: WindowOpenPop, now: TimeInterval) -> Int {
        counter += 1
        entries[pop.id] = Entry(token: counter, pop: pop, coveredAt: now)
        return counter
    }

    /// A capture of `id` read `verdict` at `now`. Nil when not waiting under `token`.
    public mutating func record(
        _ id: WindowID, token: Int, verdict: SnapshotFreshVerdict, now: TimeInterval
    ) -> Step? {
        guard isWaiting(id, token: token), var entry = entries[id] else {
            return nil
        }
        if verdict == .fresh {
            entry.popping = true
            entries[id] = entry
            return .pop(entry.pop, waited: now - entry.coveredAt)
        }
        entry.last = verdict
        entries[id] = entry
        guard now + Self.retryInterval < entry.coveredAt + Self.maxWait else {
            return .wait
        }
        return .retry(after: Self.retryInterval)
    }

    /// The wait of `id` ends at `now`: the reason when it was still waiting
    /// under `token` (it leaves the book), else nil.
    public mutating func expire(_ id: WindowID, token: Int, now: TimeInterval) -> WindowOpenRevealReason? {
        guard isWaiting(id, token: token), let entry = entries[id],
              now + 1e-9 >= entry.coveredAt + Self.maxWait
        else {
            return nil
        }
        entries.removeValue(forKey: id)
        switch entry.last {
        case .blank:
            return .blank
        case .partial, .stale:
            return .timeout
        case .fresh, .unknown, nil:
            return .noCapture
        }
    }

    /// The pop of `id` under `token` ended: true when it leaves the book.
    public mutating func popped(_ id: WindowID, token: Int) -> Bool {
        guard let entry = entries[id], entry.token == token, entry.popping else {
            return false
        }
        entries.removeValue(forKey: id)
        return true
    }

    /// The latest `targets` of the flight: the covered windows whose target
    /// moved (or is gone) leave the book, sorted.
    public mutating func retarget(_ targets: [WindowID: CGRect]) -> [WindowID] {
        let moved = entries.keys.sorted().filter { id in
            guard let target = targets[id] else {
                return true
            }
            return windowOpenTargetMoved(entries[id]!.pop.to, target)
        }
        for id in moved {
            entries.removeValue(forKey: id)
        }
        return moved
    }

    /// The flight is over: every covered window, sorted.
    public mutating func removeAll() -> [WindowID] {
        defer { entries.removeAll() }
        return entries.keys.sorted()
    }
}

private let windowOpenTargetTolerance: CGFloat = 1

private func windowOpenTargetMoved(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) > windowOpenTargetTolerance || abs(a.minY - b.minY) > windowOpenTargetTolerance
        || snapshotResized(from: a.size, to: b.size, tolerance: windowOpenTargetTolerance)
}

/// `snapshot open pop id=P:E waited ms=N` (debug): the window redrew at its
/// target N ms after the pass that opened it and pops in.
public func windowOpenPopLine(_ id: WindowID, waited: TimeInterval) -> String {
    "snapshot open pop id=\(id.pid):\(id.elementID) waited ms=\(Int((waited * 1000).rounded()))"
}

/// `snapshot open reveal id=P:E reason=<reason>` (debug): shown without the pop.
public func windowOpenRevealLine(_ id: WindowID, reason: WindowOpenRevealReason) -> String {
    "snapshot open reveal id=\(id.pid):\(id.elementID) reason=\(reason.rawValue)"
}
