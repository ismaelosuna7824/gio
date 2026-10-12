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
//
// SM-29: live (2026-10-12, VS Code Alt+F, 60 fps recording) the overlay left
// while the resized window still showed an unpainted black box where it grew
// (2 frames), then its old layout in the new frame (2 frames): the app was
// trusted, so the check never looked, and the blank test only sees a fully
// blank window. A resized window is now always checked; the region it grew
// into must read painted (`snapshotGrownStrips`, `snapshotStripUnpainted`),
// and a window caught repainting is released only once two painted reads
// match (`snapshotPaintStable`).

/// One paint check of one window: a tiny capture at its target frame and the
/// SM-10 blank test (sparse grid confirmed by the dense scan); SM-29: for a
/// resized window, its size and the region it grew into.
public enum SnapshotPaintVerdict: Equatable, Sendable {
    case painted
    case blank
    /// SM-29: resized, and not yet at its new size or the region it grew
    /// into still unpainted.
    case partial
    /// Not captured (no match, capture failed): cannot hold the overlay.
    case unknown
}

/// SM-29: what the paint check needs about one window.
public struct SnapshotPaintProbe: Equatable, Sendable {
    /// The target frame (already written).
    public let frame: CGRect
    /// The size it had at the flight start when it changed size, else nil.
    public let resizedFrom: CGSize?
    /// The content background its image showed (SM-27 edge fill), if known.
    public let background: ThemeColor?

    public init(frame: CGRect, resizedFrom: CGSize? = nil, background: ThemeColor? = nil) {
        self.frame = frame
        self.resizedFrom = resizedFrom
        self.background = background
    }
}

/// One check's answer: a verdict per window (a window missing counts as
/// `unknown`) and, SM-29, the sparse samples of each capture, for
/// `snapshotPaintStable`.
public struct SnapshotPaintAnswer: Equatable, Sendable {
    public var verdicts: [WindowID: SnapshotPaintVerdict]
    public var samples: [WindowID: [UInt32]]

    public init(verdicts: [WindowID: SnapshotPaintVerdict] = [:], samples: [WindowID: [UInt32]] = [:]) {
        self.verdicts = verdicts
        self.samples = samples
    }
}

/// Whether a window of `start` size is resized at `target` size: either
/// side changed by more than `tolerance` points.
public func snapshotResized(from start: CGSize, to target: CGSize, tolerance: CGFloat = 1) -> Bool {
    abs(start.width - target.width) > tolerance || abs(start.height - target.height) > tolerance
}

/// SM-29: the windows whose size changed between their flight start and
/// their target (a window without a start or a target is not known to be).
public func snapshotResizedWindows(starts: [WindowID: CGRect], targets: [WindowID: CGRect]) -> Set<WindowID> {
    Set(targets.compactMap { id, target in
        starts[id].map { snapshotResized(from: $0.size, to: target.size) } == true ? id : nil
    })
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
        let resized = snapshotResized(from: start.size, to: target.size, tolerance: tolerance)
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

/// SM-29: the regions of a paint-check capture (`pixelWidth` x
/// `pixelHeight` of a window at `target` size, image pixels, top-left
/// origin) the window grew into from `start` size: the strip right of the
/// old width and the strip below the old height. Apps keep their old content
/// at the top-left until they repaint (live: VS Code's old layout at its old
/// width, black beyond it); the vertical anchor is inferred. Inset from the
/// old edge and the window's rim (2 pt, at least 1 px) and clear of the
/// rounded corners, so a uniform strip means nothing was drawn there. Empty
/// for a shrink or a growth thinner than a pixel.
public func snapshotGrownStrips(from start: CGSize, to target: CGSize, pixelWidth: Int, pixelHeight: Int) -> [CGRect] {
    guard target.width > 0, target.height > 0, pixelWidth > 0, pixelHeight > 0 else {
        return []
    }
    let perPoint = CGFloat(pixelWidth) / target.width
    let inset = max(1, Int((2 * perPoint).rounded()))
    let corner = Int((overlayWindowCornerRadius * perPoint).rounded(.up))
    var strips: [CGRect] = []
    if target.width > start.width {
        let left = Int((CGFloat(pixelWidth) * start.width / target.width).rounded(.up)) + inset
        let right = pixelWidth - inset
        if right > left, pixelHeight - 2 * corner > 0 {
            strips.append(CGRect(x: left, y: corner, width: right - left, height: pixelHeight - 2 * corner))
        }
    }
    if target.height > start.height {
        let top = Int((CGFloat(pixelHeight) * start.height / target.height).rounded(.up)) + inset
        let bottom = pixelHeight - inset
        if bottom > top, pixelWidth - 2 * corner > 0 {
            strips.append(CGRect(x: corner, y: top, width: pixelWidth - 2 * corner, height: bottom - top))
        }
    }
    return strips
}

/// SM-29: largest per-channel difference (0...1) between a uniform strip
/// and the window's background that still counts as that background.
public let snapshotStripBackgroundTolerance = 0.04

/// SM-29: whether a grown strip (`samples`: packed premultiplied RGBA, alpha
/// in the low byte) shows nothing drawn: fully transparent, or one uniform
/// colour that is not the window's `background` (its SM-27 edge fill), or
/// black when the background is unknown. Content (any two opaque samples
/// differ) or the background itself reads painted; no samples, no evidence.
public func snapshotStripUnpainted(samples: [UInt32], background: ThemeColor?) -> Bool {
    guard !samples.isEmpty else {
        return false
    }
    let opaque = samples.filter { $0 & 0xFF != 0 }
    guard let first = opaque.first else {
        return true
    }
    guard opaque.allSatisfy({ $0 == first }) else {
        return false
    }
    let alpha = Double(first & 0xFF)
    let channels: [Double] = [24, 16, 8].map { min(Double((first >> UInt32($0)) & 0xFF) / alpha, 1) }
    let reference: [Double] = background.map { [$0.red, $0.green, $0.blue] } ?? [0, 0, 0]
    let matches = zip(channels, reference).allSatisfy { abs($0 - $1) <= snapshotStripBackgroundTolerance }
    return background == nil ? matches : !matches
}

/// SM-29: the verdict of one capture. A resized window the WindowServer
/// still reports at its start size (`windowSize`, nil when unknown) has not
/// taken the write yet: partial. Otherwise the SM-10 blank test, then any
/// unpainted grown strip (`strips`: the samples of `snapshotGrownStrips`):
/// partial. A window at another size (the app chose one, a minimum) is
/// judged on its capture.
public func snapshotPaintVerdict(
    _ probe: SnapshotPaintProbe, windowSize: CGSize?, samples: [UInt32], dense: () -> [UInt32], strips: [[UInt32]]
) -> SnapshotPaintVerdict {
    if let start = probe.resizedFrom, let windowSize,
       !snapshotResized(from: windowSize, to: start, tolerance: 2),
       snapshotResized(from: windowSize, to: probe.frame.size, tolerance: 2) {
        return .partial
    }
    if snapshotLooksBlank(samples: samples, dense: dense) {
        return .blank
    }
    if strips.contains(where: { snapshotStripUnpainted(samples: $0, background: probe.background) }) {
        return .partial
    }
    return .painted
}

/// SM-29: two painted reads of one window show the same content: the same
/// number of samples and at most one in sixteen differs by more than 16 in
/// a channel (a blinking cursor, scaling noise). A stale layout and the
/// final one differ in many more.
public func snapshotPaintStable(_ previous: [UInt32], _ next: [UInt32]) -> Bool {
    guard !previous.isEmpty, previous.count == next.count else {
        return false
    }
    let changed = zip(previous, next).reduce(0) { count, pair in
        let moved = stride(from: 0, through: 24, by: 8).contains { shift in
            abs(Int((pair.0 >> UInt32(shift)) & 0xFF) - Int((pair.1 >> UInt32(shift)) & 0xFF)) > 16
        }
        return moved ? count + 1 : count
    }
    return changed <= previous.count / 16
}

/// SM-29: what held the overlay besides a blank window: a resized window
/// read partly painted (`partial`), or a painted read that a later one
/// contradicted (`stale`, the old layout in the new frame).
public enum SnapshotHandoffHoldReason: String, Equatable, Sendable {
    case partial, stale
}

/// `snapshot handoff waited ms=N windows=N painted=N [resized=N]
/// [held=partial|stale]`: info when the overlay was held (a window read
/// unpainted at a check, or the cap was reached), debug otherwise. SM-29:
/// `resized` counts the checked windows that changed size, `held` names a
/// partial or stale paint.
public struct SnapshotHandoffSummary: Equatable, Sendable {
    public let waitedMilliseconds: Int
    public let windows: Int
    public let painted: Int
    public let held: Bool
    public let resized: Int
    public let reason: SnapshotHandoffHoldReason?

    public init(
        waitedMilliseconds: Int, windows: Int, painted: Int, held: Bool, resized: Int = 0,
        reason: SnapshotHandoffHoldReason? = nil
    ) {
        self.waitedMilliseconds = waitedMilliseconds
        self.windows = windows
        self.painted = painted
        self.held = held
        self.resized = resized
        self.reason = reason
    }

    public var logLevel: LogLevel { held ? .info : .debug }

    public var logLine: String {
        var line = "snapshot handoff waited ms=\(waitedMilliseconds) windows=\(windows) painted=\(painted)"
        if resized > 0 {
            line += " resized=\(resized)"
        }
        if let reason {
            line += " held=\(reason.rawValue)"
        }
        return line
    }
}

/// The hold at the deadline. `prepare` (SM-19: the early check before the
/// deadline) and `begin` return a token; answers and the cap of an older
/// token (a retarget, an abort or an end cancelled the check or the hold)
/// are ignored. One release per hold. SM-29: a window that read `partial`
/// is caught repainting, so its first painted read may be an intermediate
/// (stale) layout: it is released only when a painted read matches the
/// previous one (`snapshotPaintStable`); a painted read without samples
/// cannot be compared and releases it.
public struct SnapshotHandoff: Equatable, Sendable {
    public static let recheckInterval: TimeInterval = 0.03
    /// SM-19: how long before the deadline the early check starts; above
    /// the live check time (median 56 ms, max 76 ms).
    public static let earlyLead: TimeInterval = 0.08
    /// Longest hold after the deadline. SM-29: live, VS Code repainted a
    /// resized window ~67 ms after the deadline; with the confirming read
    /// (30 ms re-check plus a ~56 ms capture) that is ~230 ms, inside it.
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
        /// SM-29: read partly painted.
        var partial: Set<WindowID> = []
    }

    private struct Hold: Equatable, Sendable {
        let startedAt: TimeInterval
        let windows: Int
        let resized: Int
        var waiting: Set<WindowID>
        var painted = 0
        var held = false
        /// SM-29: windows read `partial` in this flight, and the samples of
        /// their latest painted read awaiting confirmation.
        var repainting: Set<WindowID> = []
        var lastRead: [WindowID: [UInt32]] = [:]
        var reason: SnapshotHandoffHoldReason?

        init(startedAt: TimeInterval, windows: Set<WindowID>, resized: Set<WindowID>, waiting: Set<WindowID>) {
            self.startedAt = startedAt
            self.windows = windows.count
            self.resized = windows.intersection(resized).count
            self.waiting = waiting
        }

        /// A window read partly painted: held, and confirmed when painted.
        mutating func caughtRepainting(_ id: WindowID) {
            held = true
            repainting.insert(id)
            lastRead[id] = nil
            if reason == nil {
                reason = .partial
            }
        }

        /// A painted read: true when it proves `id` painted for good.
        mutating func confirms(_ id: WindowID, samples: [UInt32]?) -> Bool {
            guard repainting.contains(id), let samples, !samples.isEmpty else {
                return true
            }
            if let previous = lastRead[id] {
                if snapshotPaintStable(previous, samples) {
                    return true
                }
                reason = .stale
            }
            lastRead[id] = samples
            return false
        }
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
    /// awaited; a window it did not cover drops it and checks again. SM-29:
    /// `resized` (counted in the summary) are the windows that changed size.
    public mutating func begin(
        windows: Set<WindowID>, resized: Set<WindowID> = [], now: TimeInterval
    ) -> (token: Int, step: Step) {
        let prepared = early
        early = nil
        guard !windows.isEmpty else {
            generation += 1
            hold = nil
            return (generation, .release(SnapshotHandoffSummary(waitedMilliseconds: 0, windows: 0, painted: 0, held: false)))
        }
        guard let prepared, windows.isSubset(of: prepared.windows) else {
            generation += 1
            hold = Hold(startedAt: now, windows: windows, resized: resized, waiting: windows)
            return (generation, .check(windows))
        }
        let waiting = windows.subtracting(prepared.cleared)
        var current = Hold(startedAt: now, windows: windows, resized: resized, waiting: waiting)
        current.painted = windows.intersection(prepared.painted).count
        current.held = !windows.isDisjoint(with: prepared.blank)
        for id in windows.intersection(prepared.partial) {
            current.caughtRepainting(id)
        }
        hold = current
        guard !waiting.isEmpty else {
            return (generation, .release(release(now: now)))
        }
        return (generation, prepared.answered ? .check(waiting) : .awaiting)
    }

    /// The answer of one check (a window missing from it counts as
    /// `unknown`; SM-29: `samples` of the captures, for the confirmation of
    /// a window caught repainting). Nil for a stale token, a released hold,
    /// or the early check (SM-19: kept for `begin`).
    public mutating func record(
        _ token: Int, verdicts: [WindowID: SnapshotPaintVerdict], samples: [WindowID: [UInt32]] = [:],
        now: TimeInterval
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
                case .partial:
                    prepared.partial.insert(id)
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
                if current.confirms(id, samples: samples[id]) {
                    current.waiting.remove(id)
                    current.painted += 1
                }
            case .unknown:
                current.waiting.remove(id)
            case .blank:
                current.held = true
                current.lastRead[id] = nil
            case .partial:
                current.caughtRepainting(id)
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
            painted: current.painted, held: current.held || !current.waiting.isEmpty, resized: current.resized,
            reason: current.reason
        )
    }
}

/// SM-19: paint statistics per app for the session. After
/// `cleanChecksToTrust` consecutive checks of an app with a painted window
/// and no blank or partial one, its windows are no longer checked; a blank
/// or partial verdict for any of its windows (hole and, SM-29, resized
/// windows are always checked) resets the run. A check where every window
/// of the app read `unknown` counts for nothing.
public struct PaintTrustBook: Equatable, Sendable {
    public static let cleanChecksToTrust = 5

    private var clean: [pid_t: Int] = [:]

    public init() {}

    public func isTrusted(_ pid: pid_t) -> Bool {
        clean[pid, default: 0] >= Self.cleanChecksToTrust
    }

    /// `candidates` without the windows of trusted apps; `always` (hole
    /// windows, SM-29 resized windows) stay.
    public func windowsToCheck(_ candidates: Set<WindowID>, always: Set<WindowID>) -> Set<WindowID> {
        candidates.filter { always.contains($0) || !isTrusted($0.pid) }
    }

    /// One check's answer: each app in it counts once.
    public mutating func record(_ verdicts: [WindowID: SnapshotPaintVerdict]) {
        var outcome: [pid_t: Bool] = [:]
        for (id, verdict) in verdicts {
            switch verdict {
            case .blank, .partial:
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
