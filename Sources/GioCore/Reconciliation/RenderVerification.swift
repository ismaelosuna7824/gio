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

/// Windows whose target intersects a viewport and whose WindowServer bounds
/// differ from their AX frame. A visible target with no on-screen entry is a
/// mismatch with `ws == nil` (SM-02c: the list only holds on-screen windows).
/// Ambiguous windows are skipped; a match whose size differs (minimum-size
/// learning) is not a mismatch.
public func findRenderMismatches(
    axFrames: [WindowID: CGRect], server: [ServerWindow],
    targets: [WindowID: CGRect], viewports: [CGRect]
) -> [RenderMismatch] {
    let checked = axFrames.filter { id, _ in
        targets[id].map { target in viewports.contains { $0.intersects(target) } } == true
    }
    let matches = matchServerWindows(axFrames: checked, server: server)
    return checked.keys.sorted().compactMap { id in
        switch matches[id] {
        case .matched(let ws)?:
            guard sameSize(ws, checked[id]!), isRenderMismatch(reference: checked[id]!, server: ws) else {
                return nil
            }
            return RenderMismatch(id: id, ax: checked[id]!, ws: ws)
        case .missing?, nil:
            return RenderMismatch(id: id, ax: checked[id]!, ws: nil)
        case .ambiguous?:
            return nil
        }
    }
}

/// Minimal sequence that forces the WindowServer to take a fresh position:
/// the target shifted 1 pt on x (inward when the target touches the
/// viewport's right edge), then the target itself. A plain rewrite of an
/// unchanged frame is skipped by AX, so the offset step is what makes the
/// app commit a new position twice.
public func planNudge(target: CGRect, viewport: CGRect) -> [CGRect] {
    let dx: CGFloat = target.maxX + 1 > viewport.maxX ? -1 : 1
    return [target.offsetBy(dx: dx, dy: 0), target]
}

/// Bounds of the check: one live token (a newer settle or a cancel
/// invalidates older checks), one nudge per window per settle, and warn
/// once per window for mismatches.
public struct RenderCheckBook: Sendable {
    private var generation = 0
    private var nudged: Set<WindowID> = []
    private var warned: Set<WindowID> = []

    public init() {}

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
        ids.filter { nudged.insert($0).inserted }
    }

    public mutating func mismatchLevel(for id: WindowID) -> LogLevel {
        warned.insert(id).inserted ? .warn : .debug
    }
}

public func renderMismatchLine(id: WindowID, app: String, ax: CGRect, ws: CGRect?) -> String {
    "render mismatch id=\(id.pid):\(id.elementID) app=\(app) ax=\(formatFrame(ax)) ws=\(ws.map(formatFrame) ?? "missing")"
}

public func renderNudgeLine(id: WindowID, app: String, fixed: Bool) -> String {
    "render nudge id=\(id.pid):\(id.elementID) app=\(app) fixed=\(fixed)"
}
