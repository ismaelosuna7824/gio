import CoreGraphics
import Foundation

// SM-02: pure decisions behind the ScreenCaptureKit capture module. The
// adapter (GioMacOS `SnapshotCapturer`) does the system calls; matching,
// coordinate conversion, exclusions, pixel sizes and budget accounting live
// here so they are tested without a screen.

/// One window the WindowServer lists (`CGWindowID` is also `SCWindow.windowID`),
/// with its bounds already in Cocoa coordinates. SM-17: `title` is the
/// listed window name (`kCGWindowName`, only with Screen Recording), held
/// in memory for the title tie-break of one matching run and dropped with
/// the candidate; descriptions and mirrors leave it out, so it never
/// reaches a log line or a failure message.
public struct SnapshotCandidate: Equatable, Sendable {
    public let windowID: UInt32
    public let pid: pid_t
    public let frame: CGRect
    public let title: String?

    public init(windowID: UInt32, pid: pid_t, frame: CGRect, title: String? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
        self.title = title
    }
}

extension SnapshotCandidate: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "SnapshotCandidate(windowID: \(windowID), pid: \(pid), frame: \(frame), titled: \(title != nil))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["windowID": windowID, "pid": pid, "frame": frame, "titled": title != nil])
    }
}

public enum SnapshotMatch: Equatable, Sendable {
    case matched(UInt32)
    /// Several same-size candidates and none equals the frame: skip, never guess.
    case ambiguous
    case missing
}

/// A display as the capture needs it: `CGDirectDisplayID` (equal to
/// `SCDisplay.displayID`), Cocoa frame and backing scale factor.
public struct SnapshotDisplay: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

public enum SnapshotBudget {
    /// Overall time allowed for one capture request. Windows still pending
    /// after it are reported as misses so the caller falls back for them.
    public static let defaultMilliseconds = 45
}

/// `SCWindow.frame` and `SCDisplay.frame` are global points with the origin
/// at the top-left of the primary display (the same space as CoreGraphics
/// window bounds and AX), y growing downwards. The engine speaks Cocoa
/// (bottom-left), so this is the same vertical flip as
/// `cocoaFrame(fromWindowServer:)`. The flip is its own inverse.
public func snapshotCocoaFrame(fromSCK frame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
    cocoaFrame(fromWindowServer: frame, displayHeight: primaryDisplayHeight)
}

/// Capture size in pixels for a window of `points` on a display of `scale`.
/// Rounded up and never below one pixel.
public func snapshotPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    (
        width: max(1, Int((points.width * scale).rounded(.up))),
        height: max(1, Int((points.height * scale).rounded(.up)))
    )
}

/// Backing scale of the display holding most of `frame`; the first display
/// when none overlaps, 2 (Retina) when there are no displays.
public func backingScale(for frame: CGRect, displays: [SnapshotDisplay]) -> CGFloat {
    var best: (scale: CGFloat, area: CGFloat)?
    for display in displays {
        let overlap = display.frame.intersection(frame)
        let area = overlap.isNull ? 0 : overlap.width * overlap.height
        if area > (best?.area ?? 0) {
            best = (display.scale, area)
        }
    }
    return best?.scale ?? displays.first?.scale ?? 2
}

/// Maps each managed window to a candidate without private APIs, like
/// `matchServerWindows` (FI-05). SM-13 pass 0: a window whose CGWindowID was
/// learned while visible (`known`, `SnapshotWindowIDBook`) takes that entry
/// when its app still lists it. Pass 1 takes the candidate of the same pid
/// whose frame equals the window's (each candidate is claimed once), only
/// when that is unique both ways (SM-13: same-size windows parked at one
/// frame are never guessed); pass 2
/// takes the unclaimed same-size candidates of the pid: exactly one matches,
/// several are ambiguous unless exactly one lies within clamp reach of the
/// frame (SM-11, parked windows). With none, pass 3 (SM-02c) takes the unique
/// same-pid candidate that is `plausiblySame` (learned minimum sizes).
public func matchSnapshotCandidates(
    managed: [WindowID: CGRect], candidates: [SnapshotCandidate], known: [WindowID: UInt32] = [:]
) -> [WindowID: SnapshotMatch] {
    var claimed: Set<Int> = []
    var result: [WindowID: SnapshotMatch] = [:]
    let ids = managed.keys.sorted()
    for id in ids {
        if let windowID = known[id], let index = candidates.indices.first(where: {
            !claimed.contains($0) && candidates[$0].pid == id.pid && candidates[$0].windowID == windowID
        }) {
            claimed.insert(index)
            result[id] = .matched(windowID)
        }
    }
    for id in ids where result[id] == nil {
        let frame = managed[id]!
        let nearby = candidates.indices.filter {
            !claimed.contains($0) && candidates[$0].pid == id.pid && near(candidates[$0].frame, frame)
        }
        let twins = ids.filter { other in
            other != id && other.pid == id.pid && result[other] == nil && near(managed[other]!, frame)
        }
        if nearby.count == 1, twins.isEmpty {
            claimed.insert(nearby[0])
            result[id] = .matched(candidates[nearby[0]].windowID)
        }
    }
    for id in ids where result[id] == nil {
        let frame = managed[id]!
        let options = candidates.indices.filter {
            !claimed.contains($0) && candidates[$0].pid == id.pid && sameSize(candidates[$0].frame, frame)
        }
        switch options.count {
        case 0:
            let nearby = candidates.indices.filter {
                !claimed.contains($0) && candidates[$0].pid == id.pid && plausiblySame(candidates[$0].frame, frame)
            }
            switch nearby.count {
            case 0: result[id] = .missing
            case 1:
                claimed.insert(nearby[0])
                result[id] = .matched(candidates[nearby[0]].windowID)
            default: result[id] = .ambiguous
            }
        case 1:
            claimed.insert(options[0])
            result[id] = .matched(candidates[options[0]].windowID)
        default:
            // SM-11: same-size windows of one app (columns of one width
            // preset) parked where macOS clamped them: the one entry within
            // clamp reach of the written frame is the window's.
            let reach = options.filter { withinClampReach(candidates[$0].frame, frame) }
            if reach.count == 1 {
                claimed.insert(reach[0])
                result[id] = .matched(candidates[reach[0]].windowID)
            } else {
                result[id] = .ambiguous
            }
        }
    }
    return result
}

/// SM-17: same-size windows of one app that frames cannot tell apart
/// (parked at one frame, never seen on screen, so SM-13 learned no id) are
/// told apart by title. For each `ambiguous` window with a non-empty AX
/// title (`titles`): its pool is the same-pid, same-size candidates no
/// window holds (`matched`), narrowed to those within clamp reach of its
/// frame when any is; exactly one candidate of the pool whose window name
/// equals the title, and no other ambiguous same-pid, same-size window with
/// that title, make it the window's. Anything else stays ambiguous (equal
/// titles, a missing title on either side), so windows are never swapped.
/// Titles are compared only; the caller drops them after this call.
public func snapshotTitleTieBreaks(
    managed: [WindowID: CGRect], candidates: [SnapshotCandidate], matches: [WindowID: SnapshotMatch],
    titles: [WindowID: String]
) -> [WindowID: UInt32] {
    let held = Set(matches.values.compactMap { match -> UInt32? in
        if case .matched(let windowID) = match { return windowID }
        return nil
    })
    let ambiguous = managed.keys.filter { matches[$0] == .ambiguous }
    var result: [WindowID: UInt32] = [:]
    for id in ambiguous {
        guard let frame = managed[id], let title = titles[id], !title.isEmpty else {
            continue
        }
        let rivals = ambiguous.contains { other in
            other != id && other.pid == id.pid && titles[other] == title
                && managed[other].map { sameSize($0, frame) } ?? false
        }
        guard !rivals else {
            continue
        }
        let options = candidates.filter {
            $0.pid == id.pid && !held.contains($0.windowID) && sameSize($0.frame, frame)
        }
        let reach = options.filter { withinClampReach($0.frame, frame) }
        let hits = (reach.isEmpty ? options : reach).filter { $0.title == title }
        if hits.count == 1 {
            result[id] = hits[0].windowID
        }
    }
    return result
}

/// SM-20: same-size windows of one app whose titles are equal or missing
/// (several "New Tab" windows) are told apart by stacking order. For each
/// group of `ambiguous` windows of one pid and one size, the pool is the
/// same-pid, same-size candidates no window holds (`matched`). `axOrder` is
/// the app's managed windows in its `kAXWindowsAttribute` order (front to
/// back) and `stacking` the on-screen `CGWindowListCopyWindowInfo` window
/// numbers (front to back). Only when the group and the pool have exactly
/// the same size, every window of the group appears once in `axOrder` and
/// every pool candidate appears in `stacking`, the group's windows (ranked
/// by `axOrder`) take the pool's candidates (ranked by `stacking`) rank to
/// rank. Anything else stays ambiguous (never a guess; an entry held by a
/// window is never taken, so windows are never swapped). Run after the
/// title tie-break (SM-17), with its matches applied.
public func snapshotOrderTieBreaks(
    managed: [WindowID: CGRect], candidates: [SnapshotCandidate], matches: [WindowID: SnapshotMatch],
    axOrder: [pid_t: [WindowID]], stacking: [UInt32]
) -> [WindowID: UInt32] {
    let held = Set(matches.values.compactMap { match -> UInt32? in
        if case .matched(let windowID) = match { return windowID }
        return nil
    })
    var groups: [(pid: pid_t, frame: CGRect, ids: Set<WindowID>)] = []
    for id in managed.keys.sorted() where matches[id] == .ambiguous {
        let frame = managed[id]!
        if let index = groups.firstIndex(where: { $0.pid == id.pid && sameSize($0.frame, frame) }) {
            groups[index].ids.insert(id)
        } else {
            groups.append((id.pid, frame, [id]))
        }
    }
    let rank = Dictionary(stacking.enumerated().map { ($1, $0) }) { first, _ in first }
    var result: [WindowID: UInt32] = [:]
    for group in groups {
        let pool = candidates.filter {
            $0.pid == group.pid && !held.contains($0.windowID) && sameSize($0.frame, group.frame)
        }
        let ranked = (axOrder[group.pid] ?? []).filter { group.ids.contains($0) }
        guard pool.count == group.ids.count, ranked.count == group.ids.count, Set(ranked).count == ranked.count,
              Set(pool.map(\.windowID)).count == pool.count, pool.allSatisfy({ rank[$0.windowID] != nil })
        else {
            continue
        }
        let stacked = pool.sorted { rank[$0.windowID]! < rank[$1.windowID]! }
        for (id, candidate) in zip(ranked, stacked) {
            result[id] = candidate.windowID
        }
    }
    return result
}

/// What told same-size windows apart: the title (SM-17) or the stacking order (SM-20).
public enum SnapshotTieBreak: String, Sendable {
    case title, order
}

/// `snapshot match tie-break id=P:E by=<title|order>` (debug; ids only, never the title).
public func snapshotTieBreakLogLine(_ id: WindowID, by: SnapshotTieBreak) -> String {
    "snapshot match tie-break id=\(id.pid):\(id.elementID) by=\(by.rawValue)"
}

/// SM-13: the CGWindowID of each window, learned while it was on screen.
/// Gio parks every same-size window of one app on one side at the same
/// frame (and macOS clamps them alike), so frames cannot tell parked
/// windows apart; the window-server id can: it is stable for the window's
/// lifetime and was matched without doubt while the window was visible
/// (a visible frame is unique per app). Matches of off-screen windows are
/// never learned. A learned id whose entry is gone from its app's listing
/// (the window closed) is forgotten. Owned by the capturer (one lock).
public struct SnapshotWindowIDBook: Sendable {
    public private(set) var known: [WindowID: UInt32] = [:]

    public init() {}

    /// `frames` are the windows the matching was run for, `candidates` the
    /// listing of their apps. SM-17: `identified` matches (the title
    /// tie-break) are proof of identity too and are learned wherever the
    /// window is, so later passes need no title.
    public mutating func learn(
        matches: [WindowID: SnapshotMatch], frames: [WindowID: CGRect], displays: [CGRect],
        candidates: [SnapshotCandidate], identified: Set<WindowID> = []
    ) {
        let listedPids = Set(frames.keys.map(\.pid))
        let listed = Set(candidates.map(\.windowID))
        known = known.filter { !listedPids.contains($0.key.pid) || listed.contains($0.value) }
        for (id, match) in matches {
            guard case .matched(let windowID) = match, let frame = frames[id],
                  identified.contains(id) || !snapshotFrameIsOffScreen(frame, displays: displays)
            else {
                continue
            }
            known[id] = windowID
        }
    }
}

/// SM-11: macOS clamps a parked window so up to `parkedStripLimit` points
/// stay on screen; its origin then lies that close to the frame Gio wrote.
func withinClampReach(_ server: CGRect, _ written: CGRect) -> Bool {
    abs(server.minX - written.minX) < parkedStripLimit && abs(server.minY - written.minY) < parkedStripLimit
}

/// Window IDs the display backdrop must leave out: the animated windows and
/// every window owned by Gio itself (overlay, focus ring, main window).
public func snapshotExclusions(
    candidates: [SnapshotCandidate], animated: Set<UInt32>, ownPid: pid_t
) -> [UInt32] {
    var excluded = animated
    for candidate in candidates where candidate.pid == ownPid {
        excluded.insert(candidate.windowID)
    }
    return excluded.sorted()
}

/// Displays that need a backdrop: those any animated window touches.
public func displaysNeedingBackdrop(windowFrames: [CGRect], displays: [SnapshotDisplay]) -> [UInt32] {
    displays.filter { display in
        windowFrames.contains { display.frame.intersects($0) }
    }.map(\.id).sorted()
}

public enum SnapshotMiss: String, Equatable, Sendable {
    /// No WindowServer entry for the window.
    case unmatched
    /// Several equally plausible entries.
    case ambiguous
    /// Matched but still pending when the budget ran out.
    case overBudget = "over-budget"
    /// Matched and captured with an error, or ScreenCaptureKit lacked the window.
    case failed
    /// SM-09: captured but blank (transparent or one flat colour); the
    /// previous image is kept instead.
    case blank
}

public struct SnapshotCaptureSummary: Equatable, Sendable {
    public let windows: Int
    public let captured: Int
    public let backdrop: Bool
    public let milliseconds: Int
    public let misses: [WindowID: SnapshotMiss]
    /// SM-09: pixels of every image captured (windows and backdrops), the cost of the run.
    public let pixels: Int
    public let reason: SnapshotCaptureReason
    /// SM-22: windows captured at half resolution.
    public let half: Int

    /// `snapshot capture windows=N captured=M backdrop=<bool> ms=T misses=K pixels=P half=H reason=<why>`
    /// (counts and timings only, never titles).
    public var logLine: String {
        "snapshot capture windows=\(windows) captured=\(captured) backdrop=\(backdrop) ms=\(milliseconds) "
            + "misses=\(misses.count) pixels=\(pixels) half=\(half) reason=\(reason.rawValue)"
    }
}

/// Budget and miss accounting. `backdrop` is true only when at least one
/// backdrop was requested and every requested one arrived. SM-22: `half`
/// is the windows requested at half resolution; the summary counts the
/// captured ones.
public func makeSnapshotSummary(
    requested: [WindowID], matches: [WindowID: SnapshotMatch], captured: Set<WindowID>,
    failed: Set<WindowID>, blank: Set<WindowID> = [], backdropsRequested: Int, backdropsCaptured: Int,
    elapsedMilliseconds: Double, pixels: Int = 0, reason: SnapshotCaptureReason = .settle,
    half: Set<WindowID> = []
) -> SnapshotCaptureSummary {
    var misses: [WindowID: SnapshotMiss] = [:]
    for id in requested where !captured.contains(id) {
        switch matches[id] ?? .missing {
        case .missing: misses[id] = .unmatched
        case .ambiguous: misses[id] = .ambiguous
        case .matched:
            misses[id] = blank.contains(id) ? .blank : failed.contains(id) ? .failed : .overBudget
        }
    }
    return SnapshotCaptureSummary(
        windows: requested.count, captured: requested.filter { captured.contains($0) }.count,
        backdrop: backdropsRequested > 0 && backdropsCaptured == backdropsRequested,
        milliseconds: Int(elapsedMilliseconds.rounded()), misses: misses, pixels: pixels, reason: reason,
        half: requested.filter { captured.contains($0) && half.contains($0) }.count
    )
}
