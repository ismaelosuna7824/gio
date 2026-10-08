import CoreGraphics
import Foundation

// SM-14: the hand-off from the overlay to the real windows. The real windows
// are written to their final frames when the layers start flying; a window
// that was not fully on screen at the flight start (parked, another
// workspace) or whose size changed has to repaint at its target, and some
// apps (Chromium/Electron) paint late. Removing the overlay at the deadline
// showed those windows blank. So at the deadline the overlay is held (the
// layers already sit at their targets, nothing moves) until every such window
// captures painted, re-checked every `recheckInterval`, at most `cap`. A
// window the capture cannot see (no match, failed capture) does not hold it.
//
// SM-19: live, every hand-off held the overlay ~56 ms after the deadline,
// the time of the check itself. The real windows are written when the
// layers start flying, so the check runs `earlyLead` before the deadline
// (`prepare`); at the deadline (`begin`) the overlay goes at once when every
// window already read painted, else it is held as before. `PaintTrustBook`
// stops checking an app's windows after a run of clean checks.

/// One paint check of one window: a tiny capture at its target frame and the
/// SM-10 blank test (sparse grid confirmed by the dense scan).
public enum SnapshotPaintVerdict: Equatable, Sendable {
    case painted
    case blank
    /// Not captured (no match, capture failed): cannot hold the overlay.
    case unknown
}

/// The windows whose paint must be proven before the overlay goes: visible
/// at their target on a display an overlay covers (`covered`), and either
/// not fully inside one of `screens` at the flight start (parked, another
/// workspace, partly off screen, or no known start) or resized. A window that
/// was fully visible and keeps its size painted before the flight.
public func snapshotPaintCheckWindows(
    starts: [WindowID: CGRect], targets: [WindowID: CGRect], screens: [CGRect], covered: [CGRect],
    tolerance: CGFloat = 1, minimumVisible: CGFloat = 8
) -> Set<WindowID> {
    var ids: Set<WindowID> = []
    for (id, target) in targets {
        let visibleAtTarget = covered.contains { display in
            let overlap = display.intersection(target)
            return !overlap.isNull && overlap.width >= minimumVisible && overlap.height >= minimumVisible
        }
        guard visibleAtTarget else {
            continue
        }
        guard let start = starts[id] else {
            ids.insert(id)
            continue
        }
        let inner = start.insetBy(dx: tolerance, dy: tolerance)
        let fullyVisible = screens.contains { $0.contains(inner) }
        let resized = abs(start.width - target.width) > tolerance || abs(start.height - target.height) > tolerance
        if !fullyVisible || resized {
            ids.insert(id)
        }
    }
    return ids
}

/// Pixel size of a paint-check capture: `width` pixels wide, the window's
/// aspect kept, at least one pixel high. Enough for the blank test, and
/// cheap to capture and scan.
public func snapshotPaintCheckPixelSize(points: CGSize, width: Int = 96) -> (width: Int, height: Int) {
    guard points.width > 0, points.height > 0 else {
        return (width, 1)
    }
    return (width, max(1, Int((CGFloat(width) * points.height / points.width).rounded())))
}

/// `snapshot handoff waited ms=N windows=N painted=N`: info when the overlay
/// was held (a window read unpainted at a check, or the cap was reached),
/// debug otherwise.
public struct SnapshotHandoffSummary: Equatable, Sendable {
    public let waitedMilliseconds: Int
    public let windows: Int
    public let painted: Int
    public let held: Bool

    public init(waitedMilliseconds: Int, windows: Int, painted: Int, held: Bool) {
        self.waitedMilliseconds = waitedMilliseconds
        self.windows = windows
        self.painted = painted
        self.held = held
    }

    public var logLevel: LogLevel { held ? .info : .debug }

    public var logLine: String {
        "snapshot handoff waited ms=\(waitedMilliseconds) windows=\(windows) painted=\(painted)"
    }
}

/// The hold at the deadline. `prepare` (SM-19: the early check before the
/// deadline) and `begin` return a token; answers and the cap of an older
/// token (a retarget, an abort or an end cancelled the check or the hold)
/// are ignored. One release per hold.
public struct SnapshotHandoff: Equatable, Sendable {
    public static let recheckInterval: TimeInterval = 0.03
    /// SM-19: how long before the deadline the early check starts; above
    /// the live check time (median 56 ms, max 76 ms).
    public static let earlyLead: TimeInterval = 0.08
    /// Longest hold after the deadline.
    public static let cap: TimeInterval = 0.3
    /// Slack for the session hop and the main-queue removal.
    public static let watchdogMargin: TimeInterval = 0.2
    /// The overlay watchdog re-armed at the deadline: the hold plus margin.
    public static var watchdogLimit: TimeInterval { cap + watchdogMargin }

    /// SM-19: when the early check of a flight landing at `deadline` starts
    /// (at once when the flight is shorter than the lead).
    public static func earlyCheckTime(deadline: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(now, deadline - earlyLead)
    }

    public enum Step: Equatable, Sendable {
        /// Check these windows now.
        case check(Set<WindowID>)
        /// Check these windows again after `after` seconds.
        case recheck(Set<WindowID>, after: TimeInterval)
        /// Remove the overlay and log the summary.
        case release(SnapshotHandoffSummary)
        /// SM-19: the early check is still out; its answer continues the hold.
        case awaiting
    }

    /// SM-19: the check before the deadline and what it read.
    private struct Early: Equatable, Sendable {
        let windows: Set<WindowID>
        var answered = false
        /// Painted or not visible to the capture: cannot hold the overlay.
        var cleared: Set<WindowID> = []
        var painted: Set<WindowID> = []
        var blank: Set<WindowID> = []
    }

    private struct Hold: Equatable, Sendable {
        let startedAt: TimeInterval
        let windows: Int
        var waiting: Set<WindowID>
        var painted = 0
        var held = false
    }

    private var generation = 0
    private var hold: Hold?
    private var early: Early?

    public init() {}

    /// The overlay is held after the deadline (not during the early check).
    public var isHolding: Bool { hold != nil }

    public func isCurrent(_ token: Int) -> Bool {
        token == generation && (hold != nil || early != nil)
    }

    /// SM-19: the early check of `windows` before the deadline: the step is
    /// `.check(windows)`; nil when there is nothing to check.
    public mutating func prepare(windows: Set<WindowID>) -> (token: Int, step: Step)? {
        generation += 1
        hold = nil
        guard !windows.isEmpty else {
            early = nil
            return nil
        }
        early = Early(windows: windows)
        return (generation, .check(windows))
    }

    /// The layers landed: hold for `windows` (none: release at once). SM-19:
    /// windows the early check read painted (or could not see) are proven;
    /// none left: release at once. An early check still out for the rest is
    /// awaited; a window it did not cover drops it and checks again.
    public mutating func begin(windows: Set<WindowID>, now: TimeInterval) -> (token: Int, step: Step) {
        let prepared = early
        early = nil
        guard !windows.isEmpty else {
            generation += 1
            hold = nil
            return (generation, .release(SnapshotHandoffSummary(waitedMilliseconds: 0, windows: 0, painted: 0, held: false)))
        }
        guard let prepared, windows.isSubset(of: prepared.windows) else {
            generation += 1
            hold = Hold(startedAt: now, windows: windows.count, waiting: windows)
            return (generation, .check(windows))
        }
        let waiting = windows.subtracting(prepared.cleared)
        var current = Hold(startedAt: now, windows: windows.count, waiting: waiting)
        current.painted = windows.intersection(prepared.painted).count
        current.held = !windows.isDisjoint(with: prepared.blank)
        hold = current
        guard !waiting.isEmpty else {
            return (generation, .release(release(now: now)))
        }
        return (generation, prepared.answered ? .check(waiting) : .awaiting)
    }

    /// The answer of one check (a window missing from it counts as
    /// `unknown`). Nil for a stale token, a released hold, or the early
    /// check (SM-19: kept for `begin`).
    public mutating func record(
        _ token: Int, verdicts: [WindowID: SnapshotPaintVerdict], now: TimeInterval
    ) -> Step? {
        guard isCurrent(token) else {
            return nil
        }
        if var prepared = early {
            prepared.answered = true
            for id in prepared.windows {
                switch verdicts[id] ?? .unknown {
                case .painted:
                    prepared.cleared.insert(id)
                    prepared.painted.insert(id)
                case .unknown:
                    prepared.cleared.insert(id)
                case .blank:
                    prepared.blank.insert(id)
                }
            }
            early = prepared
            return nil
        }
        guard var current = hold else {
            return nil
        }
        for id in current.waiting {
            switch verdicts[id] ?? .unknown {
            case .painted:
                current.waiting.remove(id)
                current.painted += 1
            case .unknown:
                current.waiting.remove(id)
            case .blank:
                current.held = true
            }
        }
        hold = current
        if current.waiting.isEmpty || now - current.startedAt >= Self.cap {
            return .release(release(now: now))
        }
        return .recheck(current.waiting, after: Self.recheckInterval)
    }

    /// The cap timer of `token` fired: the summary when the hold is still
    /// on and the cap is reached, else nil.
    public mutating func capReached(_ token: Int, now: TimeInterval) -> SnapshotHandoffSummary? {
        guard token == generation, let current = hold, now - current.startedAt >= Self.cap - 1e-9 else {
            return nil
        }
        hold?.held = true
        return release(now: now)
    }

    /// A retarget, an abort or an end: the hold is over without a release.
    public mutating func cancel() {
        generation += 1
        hold = nil
        early = nil
    }

    private mutating func release(now: TimeInterval) -> SnapshotHandoffSummary {
        let current = hold!
        hold = nil
        return SnapshotHandoffSummary(
            waitedMilliseconds: Int(((now - current.startedAt) * 1000).rounded()), windows: current.windows,
            painted: current.painted, held: current.held || !current.waiting.isEmpty
        )
    }
}

/// SM-19: paint statistics per app for the session. After
/// `cleanChecksToTrust` consecutive checks of an app with a painted window
/// and no blank one, its windows are no longer checked; a blank verdict for
/// any of its windows (a hole window is always checked) resets the run.
/// A check where every window of the app read `unknown` counts for nothing.
public struct PaintTrustBook: Equatable, Sendable {
    public static let cleanChecksToTrust = 5

    private var clean: [pid_t: Int] = [:]

    public init() {}

    public func isTrusted(_ pid: pid_t) -> Bool {
        clean[pid, default: 0] >= Self.cleanChecksToTrust
    }

    /// `candidates` without the windows of trusted apps; `holes` stay.
    public func windowsToCheck(_ candidates: Set<WindowID>, holes: Set<WindowID>) -> Set<WindowID> {
        candidates.filter { holes.contains($0) || !isTrusted($0.pid) }
    }

    /// One check's answer: each app in it counts once.
    public mutating func record(_ verdicts: [WindowID: SnapshotPaintVerdict]) {
        var outcome: [pid_t: Bool] = [:]
        for (id, verdict) in verdicts {
            switch verdict {
            case .blank:
                outcome[id.pid] = false
            case .painted:
                if outcome[id.pid] == nil {
                    outcome[id.pid] = true
                }
            case .unknown:
                break
            }
        }
        for (pid, passed) in outcome {
            clean[pid] = passed ? clean[pid, default: 0] + 1 : 0
        }
    }
}
