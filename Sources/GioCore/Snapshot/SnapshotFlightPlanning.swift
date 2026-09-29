import CoreGraphics
import Foundation

// SM-04: the pure decisions of the snapshot renderer at motion start and on
// retarget. The overlay is opaque (wallpaper backdrop), so every window that
// is visible at the start or at the end of the motion on an involved display
// must have a layer: a window without an image would vanish for the flight.
// The simplest artifact-free rule is therefore all-or-nothing at the start
// (AX motion for the whole run when any image is missing) and, mid-flight,
// windows without an image are written once and revealed when the overlay
// ends.

public enum SnapshotFallbackReason: String, Equatable, Sendable {
    case cacheMiss = "cache-miss"
    case noBackdrop = "no-backdrop"
    case nothingVisible = "nothing-visible"
}

public struct SnapshotFlightItem: Equatable, Sendable {
    public let id: WindowID
    public let from: CGRect
    public let to: CGRect
    public let displayIndex: Int

    public init(id: WindowID, from: CGRect, to: CGRect, displayIndex: Int) {
        self.id = id
        self.from = from
        self.to = to
        self.displayIndex = displayIndex
    }
}

public enum SnapshotFlightDecision: Equatable, Sendable {
    case snapshot(items: [SnapshotFlightItem])
    case fallback(reason: SnapshotFallbackReason, missing: [WindowID])

    /// The one write each real window gets, at motion start.
    public var finalFrames: [WindowID: CGRect] {
        guard case .snapshot(let items) = self else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.to) })
    }
}

private let flightMoveTolerance: CGFloat = 1

private func moves(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.origin.x - b.origin.x) > flightMoveTolerance || abs(a.origin.y - b.origin.y) > flightMoveTolerance
        || abs(a.width - b.width) > flightMoveTolerance || abs(a.height - b.height) > flightMoveTolerance
}

/// `starts` are the windows' current physical frames, `targets` the frames
/// this pass ends with (visible and parked alike), Cocoa coordinates.
public func planSnapshotFlight(
    starts: [WindowID: CGRect], targets: [WindowID: CGRect], displays: [CGRect],
    hasImage: (WindowID) -> Bool, backdropReady: (Int) -> Bool
) -> SnapshotFlightDecision {
    var entries: [SnapshotFlightItem] = []
    for id in targets.keys.sorted() {
        let to = targets[id]!
        let from = starts[id] ?? to
        if let index = overlayDisplayIndex(from: from, to: to, displays: displays) {
            entries.append(SnapshotFlightItem(id: id, from: from, to: to, displayIndex: index))
        }
    }
    let animatedDisplays = Set(entries.filter { moves($0.from, $0.to) }.map(\.displayIndex))
    guard !animatedDisplays.isEmpty else {
        return .fallback(reason: .nothingVisible, missing: [])
    }
    let items = entries.filter { animatedDisplays.contains($0.displayIndex) }
    let missing = items.filter { !hasImage($0.id) }.map(\.id)
    guard missing.isEmpty else {
        return .fallback(reason: .cacheMiss, missing: missing)
    }
    guard animatedDisplays.allSatisfy(backdropReady) else {
        return .fallback(reason: .noBackdrop, missing: [])
    }
    return .snapshot(items: items)
}

public struct SnapshotRetargetPlan: Equatable, Sendable {
    /// Layers already flying and their new final frames.
    public var retargets: [WindowID: CGRect]
    /// Newly involved windows that have an image: new layers.
    public var adds: [SnapshotFlightItem]
    /// Newly involved windows without an image: written once, hidden under
    /// the overlay, revealed when it ends.
    public var uncovered: [WindowID]
}

public func planSnapshotRetarget(
    active: Set<WindowID>, starts: [WindowID: CGRect], targets: [WindowID: CGRect],
    displays: [CGRect], activeDisplays: Set<Int>, hasImage: (WindowID) -> Bool
) -> SnapshotRetargetPlan {
    var plan = SnapshotRetargetPlan(retargets: [:], adds: [], uncovered: [])
    for id in targets.keys.sorted() {
        let to = targets[id]!
        if active.contains(id) {
            plan.retargets[id] = to
            continue
        }
        let from = starts[id] ?? to
        guard let index = overlayDisplayIndex(from: from, to: to, displays: displays),
              activeDisplays.contains(index)
        else {
            continue
        }
        if hasImage(id) {
            plan.adds.append(SnapshotFlightItem(id: id, from: from, to: to, displayIndex: index))
        } else {
            plan.uncovered.append(id)
        }
    }
    return plan
}

/// A flight settles when its layers finished AND the real windows' final
/// exact pass settled. Every begin/retarget issues a new token; results of
/// older tokens are ignored, and `settle` is reported once.
public struct SnapshotFlightGate: Equatable, Sendable {
    private var token = 0
    private var live = false
    private var layersDone = false
    private var passDone = false

    public init() {}

    public var isActive: Bool { live }
    public var currentToken: Int { token }

    public mutating func begin() -> Int {
        token += 1
        live = true
        layersDone = false
        passDone = false
        return token
    }

    public mutating func retarget() -> Int {
        begin()
    }

    /// True exactly when this call completed the pair for the live token.
    public mutating func layersFinished(_ token: Int) -> Bool {
        guard live, token == self.token else {
            return false
        }
        layersDone = true
        return settleIfReady()
    }

    public mutating func passSettled(_ token: Int) -> Bool {
        guard live, token == self.token else {
            return false
        }
        passDone = true
        return settleIfReady()
    }

    public mutating func abort() {
        token += 1
        live = false
    }

    private mutating func settleIfReady() -> Bool {
        guard layersDone, passDone else {
            return false
        }
        live = false
        return true
    }
}

/// `snapshot flight layers=N cacheAgeMs=M duration=Xms` (counts and timings).
public func snapshotFlightLine(layers: Int, cacheAgeMilliseconds: Int, duration: TimeInterval) -> String {
    "snapshot flight layers=\(layers) cacheAgeMs=\(cacheAgeMilliseconds) duration=\(Int((duration * 1000).rounded()))ms"
}

/// `snapshot fallback reason=cache-miss ids=N`
public func snapshotFallbackLine(reason: SnapshotFallbackReason, count: Int) -> String {
    "snapshot fallback reason=\(reason.rawValue) ids=\(count)"
}
