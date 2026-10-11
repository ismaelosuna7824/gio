import CoreGraphics
import Foundation

/// PF-L: one window the WindowServer moves in a transaction: its
/// `CGWindowID` and the Cocoa frame whose origin it moves to. The size is
/// never changed by this transport.
public struct WindowServerMove: Equatable, Sendable {
    public let windowID: UInt32
    public let frame: CGRect

    public init(windowID: UInt32, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

/// PF-L: the private WindowServer transport (SkyLight, `GioMacOS`). It moves
/// windows instantly and atomically, without a round trip through the app;
/// the app does not necessarily learn its new position, so an Accessibility
/// write always follows (`WindowReconciler` keeps the windows pending until
/// it did). Only `WindowReconciler` calls it (invariant 3).
public protocol WindowServerMover: AnyObject {
    /// The window's `CGWindowID`; nil when unknown (it keeps the AX path).
    func windowServerID(of id: WindowID) -> UInt32?
    /// Moves every window in one transaction; false when nothing was committed.
    func commit(_ moves: [WindowServerMove]) -> Bool
    /// PF-M: where the WindowServer draws `windowIDs` now (Cocoa frames),
    /// for the runtime probe; unlisted windows are absent.
    func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect]
}

public extension WindowServerMover {
    func frames(of windowIDs: [UInt32]) -> [UInt32: CGRect] { [:] }
}

/// PF-L: whether the WindowServer transport is in use, and why (log-safe).
public struct WindowServerTransportStatus: Equatable, Sendable {
    public let available: Bool
    public let reason: String

    public init(available: Bool, reason: String) {
        self.available = available
        self.reason = reason
    }

    /// `skylight available=<bool> reason=<reason>`.
    public var logLine: String {
        "skylight available=\(available) reason=\(reason)"
    }
}

/// PF-L: `[behavior] skylight` off, or a private symbol missing at runtime,
/// keeps the Accessibility-only path. PF-M: so does a failed runtime probe;
/// a verified one says so.
public func windowServerTransportStatus(
    enabled: Bool, missingSymbols: [String], probe: WindowServerProbeState = .unverified
) -> WindowServerTransportStatus {
    guard enabled else {
        return WindowServerTransportStatus(available: false, reason: "config-off")
    }
    guard missingSymbols.isEmpty else {
        return WindowServerTransportStatus(
            available: false, reason: "missing-symbols:" + missingSymbols.joined(separator: ",")
        )
    }
    switch probe {
    case .failed:
        return WindowServerTransportStatus(available: false, reason: "probe-failed")
    case .verified:
        return WindowServerTransportStatus(available: true, reason: "probe-verified")
    case .unverified:
        return WindowServerTransportStatus(available: true, reason: "symbols-resolved")
    }
}

/// PF-M: whether SkyLight moves of other apps' windows take effect here.
public enum WindowServerProbeState: String, Equatable, Sendable {
    case unverified, verified, failed
}

/// PF-M: the runtime probe, fed by real motion and nothing else (it never
/// moves a window itself). During a WindowServer flight no Accessibility
/// write touches the window, so where the WindowServer draws it before the
/// next tick's commit tells: at a frame Gio committed, the moves work
/// (`verified`); still at the frame the window had before its first move
/// (and that frame is none Gio committed) on `failureObservations`
/// observations, they do not (`failed`). Anything else (the window elsewhere
/// or not listed) proves nothing. Instant passes do not feed it: their
/// Accessibility write follows at once and would move the window either way.
/// Pure; owned by `WindowReconciler` on the calling thread.
public struct WindowServerProbe: Sendable {
    public static let failureObservations = 3
    /// Within this many points a drawn origin matches a frame.
    static let slack: CGFloat = 2
    /// Committed frames kept per window while unverified.
    static let keptMoves = 16

    public private(set) var state: WindowServerProbeState = .unverified
    private var started: [UInt32: CGRect] = [:]
    private var committed: [UInt32: [CGRect]] = [:]
    private var stuck = 0

    public init() {}

    /// A WindowServer move of `windowID` from `from` (where it was) to `to`.
    public mutating func moved(windowID: UInt32, from: CGRect, to: CGRect) {
        guard state == .unverified else {
            return
        }
        if started[windowID] == nil {
            started[windowID] = from
        }
        var frames = committed[windowID, default: []]
        frames.append(to)
        if frames.count > Self.keptMoves {
            frames.removeFirst(frames.count - Self.keptMoves)
        }
        committed[windowID] = frames
    }

    /// Windows worth looking at (moved before, at most `limit`), sorted.
    public func observationTargets(limit: Int = 2) -> [UInt32] {
        guard state == .unverified else {
            return []
        }
        return Array(committed.keys.sorted().prefix(limit))
    }

    /// Where the WindowServer draws the targets now.
    public mutating func observe(_ drawn: [UInt32: CGRect]) {
        guard state == .unverified else {
            return
        }
        var sawStuck = false
        for (windowID, frame) in drawn {
            let moves = committed[windowID] ?? []
            if moves.contains(where: { near($0, frame) }) {
                state = .verified
                started = [:]
                committed = [:]
                return
            }
            if let start = started[windowID], near(start, frame), !moves.contains(where: { near($0, start) }) {
                sawStuck = true
            }
        }
        guard sawStuck else {
            return
        }
        stuck += 1
        if stuck >= Self.failureObservations {
            state = .failed
            started = [:]
            committed = [:]
        }
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= Self.slack && abs(a.minY - b.minY) <= Self.slack
    }
}

/// PF-M: more than a parking sliver of `frame` shows in one of `viewports`,
/// on both axes (a window hanging below a display keeps a 1 pt strip too).
func showsOnScreen(_ frame: CGRect, in viewports: [CGRect]) -> Bool {
    viewports.contains { viewport in
        let inside = frame.intersection(viewport)
        return !inside.isNull && inside.width > parkingSliver * 2 && inside.height > parkingSliver * 2
    }
}

/// PF-L: the status line once at startup, then only when it changes.
public struct WindowServerStatusLogGate: Sendable {
    private var last: WindowServerTransportStatus?

    public init() {}

    public mutating func line(for status: WindowServerTransportStatus) -> String? {
        guard status != last else {
            return nil
        }
        last = status
        return status.logLine
    }
}

/// PF-L: the windows of one pass that the WindowServer moves before their
/// Accessibility write: parks (on a display now, parked target) and reveals
/// (on no display now, visible target). Moves between two hidden frames
/// and between two visible ones stay on Accessibility alone (nothing to see,
/// and only the app can lay out a visible window); so does a window whose
/// current frame Gio does not know, and every window of Gio's own pid.
public func planWindowServerFirst(
    visible: [WindowID: CGRect], parked: [WindowID: ParkedTarget],
    current: [WindowID: CGRect], displays: [CGRect], ownPID: pid_t
) -> Set<WindowID> {
    func shown(_ frame: CGRect) -> Bool {
        showsOnScreen(frame, in: displays)
    }
    var first: Set<WindowID> = []
    for (id, target) in parked where id.pid != ownPID {
        if let now = current[id], shown(now) || showsOnScreen(now, in: [target.display]) {
            first.insert(id)
        }
    }
    for (id, target) in visible where id.pid != ownPID && parked[id] == nil {
        if let now = current[id], !shown(now), shown(target) {
            first.insert(id)
        }
    }
    return first
}

/// PF-L: a `current` frame for the lean writer that differs from `frame`
/// only in position, so the follow-up writes the position the WindowServer
/// already shows (the app may still believe its old one) and nothing else.
func forcingPosition(_ frame: CGRect) -> CGRect {
    frame.offsetBy(dx: frameWriteTolerance * 4, dy: 0)
}

/// PF-L: windows the WindowServer moved that no Accessibility write has
/// followed yet, with the frame it put them at. Every move gets a sequence
/// number; a write folds an entry away only when it followed that very move
/// (a pass dispatched under an overlay folds later, after newer moves may
/// have happened). Owned by `WindowReconciler`, calling thread only.
struct WindowServerLedger {
    private var entries: [WindowID: (frame: CGRect, move: Int)] = [:]
    private var moves = 0

    var frames: [WindowID: CGRect] {
        entries.mapValues(\.frame)
    }

    func contains(_ id: WindowID) -> Bool {
        entries[id] != nil
    }

    mutating func record(_ id: WindowID, frame: CGRect) {
        moves += 1
        entries[id] = (frame, moves)
    }

    /// The moves a pass's writes of `ids` follow.
    func snapshot(_ ids: some Sequence<WindowID>) -> [WindowID: Int] {
        var result: [WindowID: Int] = [:]
        for id in ids {
            if let entry = entries[id] {
                result[id] = entry.move
            }
        }
        return result
    }

    /// Windows a pass wrote (or found gone) no longer wait for Accessibility.
    mutating func followed(_ report: ReconcileReport, snapshot: [WindowID: Int]) {
        followed(report.applied + report.parked + report.vanished, snapshot: snapshot)
    }

    mutating func followed(_ ids: some Sequence<WindowID>, snapshot: [WindowID: Int]) {
        for id in ids where snapshot[id] != nil && entries[id]?.move == snapshot[id] {
            entries.removeValue(forKey: id)
        }
    }

    mutating func forget(pid: pid_t) {
        entries = entries.filter { $0.key.pid != pid }
    }
}
