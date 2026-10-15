import CoreGraphics
import Foundation

// FI-05: Accessibility can report a window at its target while the
// WindowServer still draws it elsewhere (Chromium/Electron after unparking).
// Everything here is pure: matching, the mismatch decision, the nudge plan
// and its bounds. The adapter reads the WindowServer; the reconciler writes.

/// One on-screen window as the WindowServer reports it, already converted to
/// Cocoa coordinates. Only pid and bounds; titles are never read.
public struct ServerWindow: Equatable, Sendable {
    public let pid: pid_t
    public let bounds: CGRect

    public init(pid: pid_t, bounds: CGRect) {
        self.pid = pid
        self.bounds = bounds
    }
}

/// One window of an app in the WindowServer's complete list (on screen or
/// not), Cocoa coordinates. Diagnostics only: where a window the on-screen
/// list lacks really is. Titles are never read.
public struct ServerWindowState: Equatable, Sendable {
    public let bounds: CGRect
    public let isOnScreen: Bool

    public init(bounds: CGRect, isOnScreen: Bool) {
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }
}

/// WindowServer bounds are global with a top-left origin (like AX); the
/// engine speaks Cocoa. Same flip as `AXVerticalFlip`, kept here so Core
/// stays free of the adapter. The flip is its own inverse.
public func cocoaFrame(fromWindowServer bounds: CGRect, displayHeight: CGFloat) -> CGRect {
    CGRect(
        x: bounds.origin.x,
        y: displayHeight - bounds.origin.y - bounds.size.height,
        width: bounds.size.width,
        height: bounds.size.height
    )
}

public enum ServerMatch: Equatable, Sendable {
    case matched(CGRect)
    /// Several same-size candidates and none equals the AX frame: skip, never guess.
    case ambiguous
    case missing
}

public let renderTolerance: CGFloat = 2

func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.origin.x - b.origin.x) <= renderTolerance && abs(a.origin.y - b.origin.y) <= renderTolerance
        && abs(a.width - b.width) <= renderTolerance && abs(a.height - b.height) <= renderTolerance
}

func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.width - b.width) <= renderTolerance && abs(a.height - b.height) <= renderTolerance
}

/// SM-02c: share of the larger frame's area the two frames must overlap.
public let nearOverlapRatio: CGFloat = 0.8

/// Same window after a size the app changed on its own (minimum-size
/// learning): the frames overlap by at least 80% of the larger area. (An
/// origin-only rule would also accept much smaller windows at the same corner.)
func plausiblySame(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = a.intersection(b)
    guard !overlap.isNull else {
        return false
    }
    let larger = max(a.width * a.height, b.width * b.height)
    return larger > 0 && overlap.width * overlap.height / larger >= nearOverlapRatio
}

/// Maps each managed window to a WindowServer entry without private APIs.
/// Candidates share the pid. Pass 1: an entry whose bounds equal the AX
/// frame is that window's (each entry is claimed once). Pass 2, for the rest:
/// unclaimed entries of the same size; exactly one matches, several are
/// ambiguous. Pass 3 (SM-02c), when no same-size entry exists: the unclaimed
/// entries of the pid that are `plausiblySame`; one matches, several are
/// ambiguous, none is missing.
public func matchServerWindows(
    axFrames: [WindowID: CGRect], server: [ServerWindow]
) -> [WindowID: ServerMatch] {
    var claimed: Set<Int> = []
    var result: [WindowID: ServerMatch] = [:]
    let ids = axFrames.keys.sorted()
    for id in ids {
        let ax = axFrames[id]!
        if let index = server.indices.first(where: { !claimed.contains($0) && server[$0].pid == id.pid && near(server[$0].bounds, ax) }) {
            claimed.insert(index)
            result[id] = .matched(server[index].bounds)
        }
    }
    for id in ids where result[id] == nil {
        let ax = axFrames[id]!
        let candidates = server.indices.filter {
            !claimed.contains($0) && server[$0].pid == id.pid && sameSize(server[$0].bounds, ax)
        }
        switch candidates.count {
        case 0:
            let nearby = server.indices.filter {
                !claimed.contains($0) && server[$0].pid == id.pid && plausiblySame(server[$0].bounds, ax)
            }
            switch nearby.count {
            case 0: result[id] = .missing
            case 1: result[id] = .matched(server[nearby[0]].bounds)
            default: result[id] = .ambiguous
            }
        case 1:
            result[id] = .matched(server[candidates[0]].bounds)
        default:
            result[id] = .ambiguous
        }
    }
    return result
}

/// True when the WindowServer draws the window more than the tolerance away
/// from `reference` in position or size.
public func isRenderMismatch(reference: CGRect, server: CGRect) -> Bool {
    !near(reference, server)
}

public struct RenderMismatch: Equatable, Sendable {
    public let id: WindowID
    public let ax: CGRect
    /// `nil`: the on-screen list has no entry for the window at all.
    public let ws: CGRect?

    public init(id: WindowID, ax: CGRect, ws: CGRect?) {
        self.id = id
        self.ax = ax
        self.ws = ws
    }
}

/// Why a checked window could not be judged. Such windows are `unknown`:
/// logged for diagnosis, never nudged.
public enum UnmatchedReason: String, Equatable, Sendable {
    /// Less than half of the window is on a display (peek/edge columns).
    case offscreenTarget
    /// Several candidate entries and none is clearly the window.
    case ambiguous
    /// No paired entry, but the app draws something over the expected area.
    case overlapsOther
}

public struct RenderUnmatched: Equatable, Sendable {
    public let id: WindowID
    public let reason: UnmatchedReason
    /// Layer-0 on-screen entries of the pid that were considered.
    public let candidates: Int

    public init(id: WindowID, reason: UnmatchedReason, candidates: Int) {
        self.id = id
        self.reason = reason
        self.candidates = candidates
    }
}

public struct RenderVerdict: Equatable, Sendable {
    public let mismatches: [RenderMismatch]
    public let unmatched: [RenderUnmatched]
}

/// Share of a window that must be on a display to be worth checking.
public let renderMinVisibleRatio: CGFloat = 0.5
/// Share of the expected area an entry of the pid must cover to count as
/// "something of the app is drawn there".
public let renderPresenceRatio: CGFloat = 0.3

private func area(_ r: CGRect) -> CGFloat {
    r.isNull ? 0 : r.width * r.height
}

private func visibleRatio(_ frame: CGRect, viewports: [CGRect]) -> CGFloat {
    let total = area(frame)
    guard total > 0 else {
        return 0
    }
    return viewports.reduce(0) { $0 + area($1.intersection(frame)) } / total
}

/// Conservative verdict. `ws == nil` (missing) only when the pid has no
/// on-screen entry covering at least 30% of the expected frame; ambiguous or
/// unmatched-but-overlapping windows are `unmatched` (unknown); windows less
/// than half on a display are skipped. A match whose size differs (minimum
/// size learning) is not a mismatch. `axFrames` should be the settled frames
/// the reconciler accepted, not the requested ones.
public func evaluateRender(
    axFrames: [WindowID: CGRect], server: [ServerWindow],
    targets: [WindowID: CGRect], viewports: [CGRect]
) -> RenderVerdict {
    var unmatched: [RenderUnmatched] = []
    var checked: [WindowID: CGRect] = [:]
    for id in axFrames.keys.sorted() {
        let frame = axFrames[id]!
        guard let target = targets[id], viewports.contains(where: { $0.intersects(target) }) else {
            continue
        }
        if visibleRatio(frame, viewports: viewports) < renderMinVisibleRatio {
            unmatched.append(RenderUnmatched(
                id: id, reason: .offscreenTarget, candidates: server.filter { $0.pid == id.pid }.count
            ))
            continue
        }
        checked[id] = frame
    }
    let matches = matchServerWindows(axFrames: checked, server: server)
    var mismatches: [RenderMismatch] = []
    for id in checked.keys.sorted() {
        let frame = checked[id]!
        let ofPid = server.filter { $0.pid == id.pid }
        switch matches[id] {
        case .matched(let ws)?:
            if sameSize(ws, frame), isRenderMismatch(reference: frame, server: ws) {
                mismatches.append(RenderMismatch(id: id, ax: frame, ws: ws))
            }
        case .missing?, nil:
            let present = ofPid.contains { area($0.bounds.intersection(frame)) / area(frame) >= renderPresenceRatio }
            if present {
                unmatched.append(RenderUnmatched(id: id, reason: .overlapsOther, candidates: ofPid.count))
            } else {
                mismatches.append(RenderMismatch(id: id, ax: frame, ws: nil))
            }
        case .ambiguous?:
            unmatched.append(RenderUnmatched(id: id, reason: .ambiguous, candidates: ofPid.count))
        }
    }
    return RenderVerdict(mismatches: mismatches, unmatched: unmatched)
}

/// Mismatches only; see `evaluateRender`.
public func findRenderMismatches(
    axFrames: [WindowID: CGRect], server: [ServerWindow],
    targets: [WindowID: CGRect], viewports: [CGRect]
) -> [RenderMismatch] {
    evaluateRender(axFrames: axFrames, server: server, targets: targets, viewports: viewports).mismatches
}

/// PF-C: how hard a nudge pushes. `position` moves the window 1 pt and back;
/// `size`, tried only after a failed position nudge, shrinks it 1 pt and
/// restores it, so the app lays out and commits a new surface.
public enum NudgeTier: String, Sendable {
    case position, size
}

/// Minimal sequence that forces the WindowServer to take a fresh frame.
/// `position`: the target shifted 1 pt on x (inward when the target touches
/// the viewport's right edge), then the target itself. A plain rewrite of an
/// unchanged frame is skipped by AX, so the offset step is what makes the
/// app commit a new position twice. `size`: the target 1 pt narrower in
/// place, then the target.
public func planNudge(target: CGRect, viewport: CGRect, tier: NudgeTier = .position) -> [CGRect] {
    switch tier {
    case .position:
        let dx: CGFloat = target.maxX + 1 > viewport.maxX ? -1 : 1
        return [target.offsetBy(dx: dx, dy: 0), target]
    case .size:
        return [CGRect(x: target.minX, y: target.minY, width: target.width - 1, height: target.height), target]
    }
}

/// Bounds of the check: one live token (a newer settle or a cancel
/// invalidates older checks), one nudge per window per settle, and warn
/// once per window for mismatches.
public struct RenderCheckBook: Sendable {
    private var generation = 0
    private var nudged: Set<WindowID> = []
    private var warned: Set<WindowID> = []
    private var unverifiable: Set<WindowID> = []

    public init() {}

    /// A nudge that did not fix the window is its last: the window becomes
    /// render-unverifiable and is no longer checked. True the first time
    /// (the caller logs once).
    public mutating func recordNudge(_ id: WindowID, fixed: Bool) -> Bool {
        fixed ? false : unverifiable.insert(id).inserted
    }

    public func isUnverifiable(_ id: WindowID) -> Bool {
        unverifiable.contains(id)
    }

    /// Frames of windows still worth checking.
    public func checkable(_ frames: [WindowID: CGRect]) -> [WindowID: CGRect] {
        frames.filter { !unverifiable.contains($0.key) }
    }

    /// Re-registered or gone windows start clean.
    public mutating func forget(_ ids: some Sequence<WindowID>) {
        for id in ids {
            unverifiable.remove(id)
            nudged.remove(id)
            warned.remove(id)
        }
    }

    /// A new settle: supersedes any pending check and resets the nudge budget.
    public mutating func schedule() -> Int {
        generation += 1
        nudged = []
        return generation
    }

    /// New motion or reflow in flight: pending checks must not run.
    public mutating func cancel() {
        generation += 1
    }

    public func isCurrent(_ token: Int) -> Bool {
        token == generation
    }

    public mutating func claimNudges(_ ids: [WindowID]) -> [WindowID] {
        ids.filter { !unverifiable.contains($0) && nudged.insert($0).inserted }
    }

    public mutating func mismatchLevel(for id: WindowID) -> LogLevel {
        warned.insert(id).inserted ? .warn : .debug
    }
}

public func renderMismatchLine(id: WindowID, app: String, ax: CGRect, ws: CGRect?) -> String {
    "render mismatch id=\(id.pid):\(id.elementID) app=\(app) ax=\(formatFrame(ax)) ws=\(ws.map(formatFrame) ?? "missing")"
}

public func renderNudgeLine(id: WindowID, app: String, tier: NudgeTier, fixed: Bool) -> String {
    "render nudge id=\(id.pid):\(id.elementID) app=\(app) tier=\(tier.rawValue) fixed=\(fixed)"
}

public func renderUnmatchedLine(id: WindowID, app: String, reason: UnmatchedReason, candidates: Int) -> String {
    "render unmatched id=\(id.pid):\(id.elementID) app=\(app) reason=\(reason.rawValue) candidates=\(candidates)"
}

public func renderUnverifiableLine(id: WindowID, app: String) -> String {
    "render unverifiable id=\(id.pid):\(id.elementID) app=\(app) reason=nudgeNotFixed"
}

/// Entries a missing-window detail lists; the rest are counted.
public let renderMissingDetailLimit = 6

/// Two displays (2026-10-14: columns empty while AX reported the windows at
/// their targets): after `render mismatch ... ws=missing`, every entry of the
/// app in the WindowServer's complete list, on screen or not, and the
/// display it overlaps most (1-based in `displays` order; `none` off every
/// display). Ids and frames only.
public func renderMissingDetailLine(id: WindowID, entries: [ServerWindowState], displays: [CGRect]) -> String {
    var line = "render missing detail id=\(id.pid):\(id.elementID) entries=\(entries.count)"
    for entry in entries.prefix(renderMissingDetailLimit) {
        let overlaps = displays.map { area($0.intersection(entry.bounds)) }
        let best = overlaps.indices.max { overlaps[$0] < overlaps[$1] }
        let display = best.flatMap { overlaps[$0] > 0 ? "\($0 + 1)" : nil } ?? "none"
        line += " [\(formatFrame(entry.bounds)) on=\(entry.isOnScreen ? "Y" : "n") display=\(display)]"
    }
    if entries.count > renderMissingDetailLimit {
        line += " more=\(entries.count - renderMissingDetailLimit)"
    }
    return line
}
