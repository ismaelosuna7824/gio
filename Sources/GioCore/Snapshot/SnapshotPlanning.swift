import CoreGraphics
import Foundation

// SM-02: pure decisions behind the ScreenCaptureKit capture module. The
// adapter (GioMacOS `SnapshotCapturer`) does the system calls; matching,
// coordinate conversion, exclusions, pixel sizes and budget accounting live
// here so they are tested without a screen.

/// One window the WindowServer lists (`CGWindowID` is also `SCWindow.windowID`),
/// with its bounds already in Cocoa coordinates.
public struct SnapshotCandidate: Equatable, Sendable {
    public let windowID: UInt32
    public let pid: pid_t
    public let frame: CGRect

    public init(windowID: UInt32, pid: pid_t, frame: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
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
/// `matchServerWindows` (FI-05): pass 1 takes the candidate of the same pid
/// whose frame equals the window's (each candidate is claimed once); pass 2
/// takes the unclaimed same-size candidates of the pid: exactly one matches,
/// several are ambiguous, none is missing.
public func matchSnapshotCandidates(
    managed: [WindowID: CGRect], candidates: [SnapshotCandidate]
) -> [WindowID: SnapshotMatch] {
    var claimed: Set<Int> = []
    var result: [WindowID: SnapshotMatch] = [:]
    let ids = managed.keys.sorted()
    for id in ids {
        let frame = managed[id]!
        if let index = candidates.indices.first(where: {
            !claimed.contains($0) && candidates[$0].pid == id.pid && near(candidates[$0].frame, frame)
        }) {
            claimed.insert(index)
            result[id] = .matched(candidates[index].windowID)
        }
    }
    for id in ids where result[id] == nil {
        let frame = managed[id]!
        let options = candidates.indices.filter {
            !claimed.contains($0) && candidates[$0].pid == id.pid && sameSize(candidates[$0].frame, frame)
        }
        switch options.count {
        case 0: result[id] = .missing
        case 1:
            claimed.insert(options[0])
            result[id] = .matched(candidates[options[0]].windowID)
        default: result[id] = .ambiguous
        }
    }
    return result
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
}

public struct SnapshotCaptureSummary: Equatable, Sendable {
    public let windows: Int
    public let captured: Int
    public let backdrop: Bool
    public let milliseconds: Int
    public let misses: [WindowID: SnapshotMiss]

    /// `snapshot capture windows=N captured=M backdrop=<bool> ms=T misses=K`
    /// (counts and timings only, never titles).
    public var logLine: String {
        "snapshot capture windows=\(windows) captured=\(captured) backdrop=\(backdrop) ms=\(milliseconds) misses=\(misses.count)"
    }
}

/// Budget and miss accounting. `backdrop` is true only when at least one
/// backdrop was requested and every requested one arrived.
public func makeSnapshotSummary(
    requested: [WindowID], matches: [WindowID: SnapshotMatch], captured: Set<WindowID>,
    failed: Set<WindowID>, backdropsRequested: Int, backdropsCaptured: Int,
    elapsedMilliseconds: Double
) -> SnapshotCaptureSummary {
    var misses: [WindowID: SnapshotMiss] = [:]
    for id in requested where !captured.contains(id) {
        switch matches[id] ?? .missing {
        case .missing: misses[id] = .unmatched
        case .ambiguous: misses[id] = .ambiguous
        case .matched: misses[id] = failed.contains(id) ? .failed : .overBudget
        }
    }
    return SnapshotCaptureSummary(
        windows: requested.count, captured: requested.filter { captured.contains($0) }.count,
        backdrop: backdropsRequested > 0 && backdropsCaptured == backdropsRequested,
        milliseconds: Int(elapsedMilliseconds.rounded()), misses: misses
    )
}
