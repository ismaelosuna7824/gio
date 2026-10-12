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
/// a verified one says so. PF-P: a retry after a failure uses it again.
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
    case .retrying:
        return WindowServerTransportStatus(available: true, reason: "probe-retrying")
    case .unverified:
        return WindowServerTransportStatus(available: true, reason: "symbols-resolved")
    }
}

/// PF-M: whether SkyLight moves of other apps' windows take effect here.
/// PF-P: `retrying` is a new trial after a failure (the transport is in use
/// again until that trial verifies or fails).
public enum WindowServerProbeState: String, Equatable, Sendable {
    case unverified, verified, failed, retrying
}

/// PF-P: one probe verdict with its evidence, for the log (window numbers,
/// origins and timings only).
public struct WindowServerProbeVerdict: Equatable, Sendable {
    public enum Result: String, Equatable, Sendable {
        case verified, failed
    }

    public let result: Result
    public let trial: Int
    /// The `CGWindowID` the verdict was read from.
    public let windowID: UInt32
    /// `match=direct|translation`, or for a failure where the window started,
    /// where it is drawn, the last frame Gio committed and how many it did.
    public let evidence: String
    /// From that window's first move in the flight to the verdict.
    public let sinceFirstMove: TimeInterval
    /// A failure: seconds until the next trial.
    public let retryAfter: TimeInterval?

    /// `skylight probe result=<verified|failed> trial=N window=<cgid> <evidence> sinceFirstMoveMs=M [retryInS=S]`
    public var logLine: String {
        var line = "skylight probe result=\(result.rawValue) trial=\(trial) window=\(windowID) \(evidence)"
            + " sinceFirstMoveMs=\(Int((sinceFirstMove * 1000).rounded()))"
        if let retryAfter {
            line += " retryInS=\(Int(retryAfter.rounded()))"
        }
        return line
    }
}

/// PF-M: the runtime probe, fed by real motion and nothing else (it never
/// moves a window itself). During a WindowServer flight no Accessibility
/// write touches the window, so where the WindowServer draws it before the
/// next tick's commit tells whether the moves take effect. Instant passes do
/// not feed it: their Accessibility write follows at once and would move the
/// window either way. Pure; owned by `WindowReconciler` on the calling thread.
///
/// PF-P, what counts:
/// - Verified: the window is drawn at a committed frame that a WindowServer
///   ignoring the moves could not show (more than `slack` from the flight's
///   start), or its drawn origin moved since the first look by exactly the
///   offset between two committed frames (the same proof in whatever
///   coordinate space the readback uses).
/// - Stuck: the drawn frame has not moved since the first look although a
///   commit at least `readbackAllowance` old lies away from every frame the
///   window could have shown at that first look. Measured live (2026-10-12,
///   a panel moved by its own process, SkyLight transactions every 8.3 ms):
///   `CGWindowListCopyWindowInfo` shows a commit after 1.0-1.2 ms (max
///   2.2 ms), so the allowance is a wide margin, not a guess at the latency.
/// - Failed: `failureObservations` consecutive stuck looks (a look where the
///   window moved elsewhere resets the count). The transport goes off until
///   `retryDelays` later, when a new trial starts; never for the whole
///   session on one flight.
/// - Evidence belongs to one flight: a window whose moves pause for
///   `staleGap` starts over, and the reconciler makes the probe forget a
///   window it moves any other way (an Accessibility write, an alignment).
public struct WindowServerProbe: Sendable {
    public static let failureObservations = 3
    /// The readback must show a commit this old.
    public static let readbackAllowance: TimeInterval = 0.05
    /// After the first failed trial, after every later one.
    public static let retryDelays: [TimeInterval] = [2, 600]
    /// Within this many points a drawn origin matches a frame.
    static let slack: CGFloat = 2
    /// Moves further apart than this are separate flights.
    static let staleGap: TimeInterval = 0.25
    /// Committed frames kept per window during a trial.
    static let keptMoves = 32

    private struct Commit: Sendable {
        let at: TimeInterval
        let frame: CGRect
    }

    private struct FirstLook: Sendable {
        let frame: CGRect
        /// Every frame the window could have been drawn at then: its start
        /// and each frame committed before the look.
        let candidates: [CGRect]
    }

    private struct Track: Sendable {
        let start: CGRect
        let firstMoveAt: TimeInterval
        var lastMoveAt: TimeInterval
        var commits: [Commit] = []
        var firstLook: FirstLook?
        var stuck = 0
    }

    public private(set) var state: WindowServerProbeState = .unverified
    /// 1 for the session's first trial, one more per retry.
    public private(set) var trial = 1
    private var failures = 0
    private var retryAt: TimeInterval?
    private var tracks: [UInt32: Track] = [:]

    public init() {}

    /// A trial is running: the transport is in use and the probe listens.
    public var isTrialRunning: Bool {
        state == .unverified || state == .retrying
    }

    /// A failed probe whose retry is due starts its next trial.
    public mutating func refresh(at now: TimeInterval) {
        guard state == .failed, let retryAt, now >= retryAt else {
            return
        }
        state = .retrying
        trial += 1
        self.retryAt = nil
        tracks = [:]
    }

    /// A WindowServer move of `windowID` from `from` (where it was) to `to`
    /// at `now`, during a flight.
    public mutating func moved(windowID: UInt32, from: CGRect, to: CGRect, at now: TimeInterval) {
        guard isTrialRunning else {
            return
        }
        var track: Track
        if let current = tracks[windowID], now - current.lastMoveAt <= Self.staleGap {
            track = current
        } else {
            // A new flight for this window: drop every track of an older one.
            tracks = tracks.filter { now - $0.value.lastMoveAt <= Self.staleGap }
            track = Track(start: from, firstMoveAt: now, lastMoveAt: now)
        }
        track.commits.append(Commit(at: now, frame: to))
        if track.commits.count > Self.keptMoves {
            track.commits.removeFirst(track.commits.count - Self.keptMoves)
        }
        track.lastMoveAt = now
        tracks[windowID] = track
    }

    /// The windows were moved outside the flight's ticks: what was seen of
    /// them proves nothing about the commits any more.
    public mutating func forget(_ windowIDs: some Sequence<UInt32>) {
        for windowID in windowIDs {
            tracks.removeValue(forKey: windowID)
        }
    }

    /// Windows worth looking at (moved in this flight, at most `limit`), sorted.
    public func observationTargets(limit: Int = 2) -> [UInt32] {
        guard isTrialRunning else {
            return []
        }
        return Array(tracks.keys.sorted().prefix(limit))
    }

    /// Where the WindowServer draws the targets at `now`, before this
    /// tick's commit. Returns the verdict when this look decided the trial.
    @discardableResult
    public mutating func observe(_ drawn: [UInt32: CGRect], at now: TimeInterval) -> WindowServerProbeVerdict? {
        guard isTrialRunning else {
            return nil
        }
        for windowID in drawn.keys.sorted() {
            guard var track = tracks[windowID], now - track.lastMoveAt <= Self.staleGap else {
                continue
            }
            let frame = drawn[windowID]!
            if let match = proof(frame, track) {
                return conclude(.verified, windowID: windowID, track: track, evidence: "match=\(match)", now: now)
            }
            if let first = track.firstLook {
                if !near(first.frame, frame) {
                    track.stuck = 0
                } else if track.commits.contains(where: { commit in
                    now - commit.at >= Self.readbackAllowance - 0.000_001
                        && !first.candidates.contains(where: { near($0, commit.frame) })
                }) {
                    track.stuck += 1
                }
            } else {
                track.firstLook = FirstLook(frame: frame, candidates: [track.start] + track.commits.map(\.frame))
            }
            tracks[windowID] = track
            if track.stuck >= Self.failureObservations {
                let last = track.commits.last?.frame ?? track.start
                let evidence = "start=\(origin(track.start)) drawn=\(origin(frame)) lastCommit=\(origin(last))"
                    + " commits=\(track.commits.count)"
                return conclude(.failed, windowID: windowID, track: track, evidence: evidence, now: now)
            }
        }
        return nil
    }

    /// `direct` or `translation` when the drawn frame proves the moves work.
    private func proof(_ frame: CGRect, _ track: Track) -> String? {
        if track.commits.contains(where: { !near($0.frame, track.start) && near($0.frame, frame) }) {
            return "direct"
        }
        guard let first = track.firstLook, !near(first.frame, frame) else {
            return nil
        }
        let dx = frame.minX - first.frame.minX
        let dy = frame.minY - first.frame.minY
        let positions = [track.start] + track.commits.map(\.frame)
        for i in positions.indices {
            for j in positions.index(after: i)..<positions.endIndex {
                let mx = positions[j].minX - positions[i].minX
                let my = positions[j].minY - positions[i].minY
                let distinct = abs(mx) > Self.slack || abs(my) > Self.slack
                if distinct && abs(mx - dx) <= Self.slack && abs(my - dy) <= Self.slack {
                    return "translation"
                }
            }
        }
        return nil
    }

    private mutating func conclude(
        _ result: WindowServerProbeVerdict.Result, windowID: UInt32, track: Track, evidence: String, now: TimeInterval
    ) -> WindowServerProbeVerdict {
        var retryAfter: TimeInterval?
        switch result {
        case .verified:
            state = .verified
            failures = 0
        case .failed:
            failures += 1
            let delay = Self.retryDelays[min(failures, Self.retryDelays.count) - 1]
            retryAt = now + delay
            retryAfter = delay
            state = .failed
        }
        tracks = [:]
        return WindowServerProbeVerdict(
            result: result, trial: trial, windowID: windowID, evidence: evidence,
            sinceFirstMove: now - track.firstMoveAt, retryAfter: retryAfter
        )
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= Self.slack && abs(a.minY - b.minY) <= Self.slack
    }

    private func origin(_ frame: CGRect) -> String {
        "(\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())))"
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
    /// Returns the ones folded away (TG-05: the ones whose write followed the
    /// newest move, so aligning them cannot undo a newer move).
    @discardableResult
    mutating func followed(_ report: ReconcileReport, snapshot: [WindowID: Int]) -> Set<WindowID> {
        followed(report.applied + report.parked + report.vanished, snapshot: snapshot)
    }

    @discardableResult
    mutating func followed(_ ids: some Sequence<WindowID>, snapshot: [WindowID: Int]) -> Set<WindowID> {
        var folded: Set<WindowID> = []
        for id in ids where snapshot[id] != nil && entries[id]?.move == snapshot[id] {
            entries.removeValue(forKey: id)
            folded.insert(id)
        }
        return folded
    }

    mutating func forget(pid: pid_t) {
        entries = entries.filter { $0.key.pid != pid }
    }
}
