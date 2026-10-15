import CoreGraphics
import Foundation

// SM-04: the pure decisions of the snapshot renderer at motion start and on
// retarget. The overlay draws an opaque picture (wallpaper backdrop) over
// every involved display. SM-16: a window without an image does not force
// the AX renderer any more. It is written once to its final frame and, when
// it is visible there, the backdrop gets a hole at that frame
// (`snapshotHoles`): the real window (painting, the panel does not occlude
// it, SM-14) shows through, and the image layers still draw above it. The
// motion falls back to AX only when no moving window has an image. SM-31:
// an `undrawn` window (its AX element vanished, or a capture found no
// WindowServer window for it on screen) has nothing to show: no layer, no
// hole, never a miss; a motion that moves only undrawn windows moves
// nothing visible.

public enum SnapshotFallbackReason: String, Equatable, Sendable {
    case cacheMiss = "cache-miss"
    case noBackdrop = "no-backdrop"
    case nothingVisible = "nothing-visible"
    /// SM-08: the overlay could not be put on screen before the real writes.
    case primeFailed = "prime-failed"
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

/// SM-16: a window that flies without a layer and is visible at its target
/// on an overlaid display: the backdrop is cut at `frame` (its target) so
/// the real window shows through.
public struct SnapshotHole: Equatable, Sendable {
    public let id: WindowID
    public let frame: CGRect
    public let displayIndex: Int

    public init(id: WindowID, frame: CGRect, displayIndex: Int) {
        self.id = id
        self.frame = frame
        self.displayIndex = displayIndex
    }
}

public enum SnapshotFlightDecision: Equatable, Sendable {
    /// `items` fly an image; `holes` are the windows without one that land
    /// visible (SM-16).
    case snapshot(items: [SnapshotFlightItem], holes: [SnapshotHole])
    case fallback(reason: SnapshotFallbackReason, missing: [WindowID])

    /// The one write each real window gets, at motion start.
    public var finalFrames: [WindowID: CGRect] {
        guard case .snapshot(let items, let holes) = self else {
            return [:]
        }
        var frames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.to) })
        for hole in holes {
            frames[hole.id] = hole.frame
        }
        return frames
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
    hasImage: (WindowID) -> Bool, backdropReady: (Int) -> Bool, undrawn: Set<WindowID> = []
) -> SnapshotFlightDecision {
    var entries: [SnapshotFlightItem] = []
    for id in targets.keys.sorted() where !undrawn.contains(id) {
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
    let involved = entries.filter { animatedDisplays.contains($0.displayIndex) }
    var items: [SnapshotFlightItem] = []
    var missing: [WindowID] = []
    for item in involved {
        if hasImage(item.id) {
            items.append(item)
        } else {
            missing.append(item.id)
        }
    }
    // SM-16: holes show the rest, but something must fly.
    guard items.contains(where: { moves($0.from, $0.to) }) else {
        return .fallback(reason: .cacheMiss, missing: missing)
    }
    guard animatedDisplays.allSatisfy(backdropReady) else {
        return .fallback(reason: .noBackdrop, missing: [])
    }
    let holes = snapshotHoles(
        layered: Set(items.map(\.id)), targets: targets, displays: displays, activeDisplays: animatedDisplays,
        undrawn: undrawn
    )
    return .snapshot(items: items, holes: holes)
}

/// SM-16: every window without a layer that is visible at its target on an
/// overlaid display (`activeDisplays`), sorted by id. Parked windows (their
/// 1 pt sliver included) and windows on displays without an overlay have no
/// hole, nor (SM-31) undrawn ones. Recomputed on every retarget with the
/// latest targets: a window that got a layer loses its hole, one uncovered
/// at the retarget gains one.
public func snapshotHoles(
    layered: Set<WindowID>, targets: [WindowID: CGRect], displays: [CGRect], activeDisplays: Set<Int>,
    undrawn: Set<WindowID> = []
) -> [SnapshotHole] {
    targets.keys.sorted().compactMap { id in
        let frame = targets[id]!
        guard !layered.contains(id), !undrawn.contains(id),
              let index = overlayDisplayIndex(from: frame, to: frame, displays: displays),
              activeDisplays.contains(index)
        else {
            return nil
        }
        return SnapshotHole(id: id, frame: frame, displayIndex: index)
    }
}

/// `snapshot holes ids=N` (debug): windows shown through the backdrop.
public func snapshotHolesLine(count: Int) -> String {
    "snapshot holes ids=\(count)"
}

public struct SnapshotRetargetPlan: Equatable, Sendable {
    /// Layers already flying and their new final frames.
    public var retargets: [WindowID: CGRect]
    /// Newly involved windows that have an image: new layers.
    public var adds: [SnapshotFlightItem]
    /// Newly involved windows without an image: written once under the
    /// overlay; visible at their target, they show through a hole (SM-16).
    public var uncovered: [WindowID]
}

/// SM-31: an undrawn window joining the flight is neither added nor uncovered.
public func planSnapshotRetarget(
    active: Set<WindowID>, starts: [WindowID: CGRect], targets: [WindowID: CGRect],
    displays: [CGRect], activeDisplays: Set<Int>, hasImage: (WindowID) -> Bool, undrawn: Set<WindowID> = []
) -> SnapshotRetargetPlan {
    var plan = SnapshotRetargetPlan(retargets: [:], adds: [], uncovered: [])
    for id in targets.keys.sorted() {
        let to = targets[id]!
        if active.contains(id) {
            plan.retargets[id] = to
            continue
        }
        let from = starts[id] ?? to
        guard !undrawn.contains(id), let index = overlayDisplayIndex(from: from, to: to, displays: displays),
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

/// `snapshot flight layers=N cacheAgeMs=M duration=Xms [fps=F]` (counts and
/// timings). `fps` is presented frames over the measured flight time (SM-12),
/// absent when nothing was measured.
public func snapshotFlightLine(
    layers: Int, cacheAgeMilliseconds: Int, duration: TimeInterval, frames: FlightFrameStats? = nil
) -> String {
    let fps = frames.map { " fps=\(Int($0.framesPerSecond.rounded()))" } ?? ""
    return "snapshot flight layers=\(layers) cacheAgeMs=\(cacheAgeMilliseconds) duration=\(Int((duration * 1000).rounded()))ms\(fps)"
}

/// `snapshot fallback reason=cache-miss ids=N`
public func snapshotFallbackLine(reason: SnapshotFallbackReason, count: Int) -> String {
    "snapshot fallback reason=\(reason.rawValue) ids=\(count)"
}

/// Why an overlay flight was cut short (SM-05).
public enum SnapshotAbortReason: String, Equatable, Sendable {
    /// The flight outlived the watchdog limit.
    case watchdog
    /// A mouse button went down: clicks must land on real windows at once.
    case mouseDown = "mouse-down"
    /// Screens changed under the flight.
    case displayChange = "display-change"

    public var logLevel: LogLevel {
        self == .watchdog ? .warn : .info
    }
}

/// `snapshot flight aborted reason=watchdog|mouse-down|display-change`
public func snapshotAbortLine(reason: SnapshotAbortReason) -> String {
    "snapshot flight aborted reason=\(reason.rawValue)"
}
