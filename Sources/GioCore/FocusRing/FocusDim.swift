import CoreGraphics
import Foundation

/// NF-06: how the focused window stands out. `ring` (default since NF-08)
/// draws the NF-01 outline; `dim` darkens the visible unfocused tiled
/// windows at rest; `none` shows nothing.
public enum FocusIndicatorKind: String, CaseIterable, Equatable, Sendable {
    case dim
    case ring
    case none
}

/// `[focus] indicator / dim-strength`.
public struct FocusSectionConfig: Equatable, Sendable {
    public static let dimStrengthRange = 0.0...0.5

    public var indicator: FocusIndicatorKind
    /// Opacity of the black fill over unfocused windows (0.0-0.5).
    public var dimStrength: Double

    public init(indicator: FocusIndicatorKind = .ring, dimStrength: Double = 0.15) {
        self.indicator = indicator
        self.dimStrength = dimStrength
    }

    /// The `[focus-ring]` overlay only runs when the ring is the indicator.
    public var showsRing: Bool { indicator == .ring }
}

/// A window as the dim model sees it: owner pid (to find it in the
/// WindowServer list) and Gio's frame for it (Cocoa coordinates).
public struct DimWindow: Equatable, Sendable {
    public var pid: pid_t
    public var frame: CGRect

    public init(pid: pid_t, frame: CGRect) {
        self.pid = pid
        self.frame = frame
    }
}

/// One dimmed window: the bounds the WindowServer draws (the overlay rounds
/// its corners like the window's) and the pieces of it to darken, already
/// minus everything in front of it and clipped to the display.
public struct FocusDimWindowRegion: Equatable, Sendable {
    public var bounds: CGRect
    public var rects: [CGRect]

    public init(bounds: CGRect, rects: [CGRect]) {
        self.bounds = bounds
        self.rects = rects
    }
}

/// What one display's overlay draws.
public struct FocusDimDisplay: Equatable, Sendable {
    public var display: CGRect
    public var windows: [FocusDimWindowRegion]

    public init(display: CGRect, windows: [FocusDimWindowRegion]) {
        self.display = display
        self.windows = windows
    }

    /// Dimmed windows on this display (the log's `regions=`).
    public var regionCount: Int { windows.count }
}

/// `base` minus `hole`: up to four non-overlapping pieces (full-width bands
/// below and above the hole, then the side pieces beside it).
public func subtractRect(_ base: CGRect, _ hole: CGRect) -> [CGRect] {
    let overlap = base.intersection(hole)
    guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
        return [base]
    }
    let pieces = [
        CGRect(x: base.minX, y: base.minY, width: base.width, height: overlap.minY - base.minY),
        CGRect(x: base.minX, y: overlap.maxY, width: base.width, height: base.maxY - overlap.maxY),
        CGRect(x: base.minX, y: overlap.minY, width: overlap.minX - base.minX, height: overlap.height),
        CGRect(x: overlap.maxX, y: overlap.minY, width: base.maxX - overlap.maxX, height: overlap.height),
    ]
    return pieces.filter { $0.width > 0 && $0.height > 0 }
}

/// Largest per-edge difference between Gio's frame and the WindowServer
/// bounds that still names the same window (apps round or clamp a little).
private let dimMatchTolerance: CGFloat = 12
/// Slivers thinner than this are not worth a fill.
private let dimMinimumPiece: CGFloat = 1

private func edgeDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    max(
        abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY),
        abs(lhs.maxX - rhs.maxX), abs(lhs.maxY - rhs.maxY)
    )
}

/// Index in `frontToBack` of the entry that draws `window`: same pid, every
/// edge within the tolerance, closest first; `used` entries are skipped.
private func serverIndex(of window: DimWindow, in frontToBack: [ServerWindow], used: Set<Int>) -> Int? {
    frontToBack.indices
        .filter { !used.contains($0) && frontToBack[$0].pid == window.pid }
        .map { ($0, edgeDistance(frontToBack[$0].bounds, window.frame)) }
        .filter { $0.1 <= dimMatchTolerance }
        .min { $0.1 < $1.1 }?.0
}

/// Pure NF-06 model. `windows` are the visible unfocused tiled windows (Gio
/// frames); `frontToBack` is the WindowServer's on-screen normal-layer list
/// in z-order, every app included (floating, popovers, other apps, Gio's own
/// windows). Each window is dimmed where it is drawn (its matched server
/// bounds) minus every entry in front of it and minus the focused window,
/// then split per display. Windows the server does not list (minimized,
/// hidden, other Space) or that are off-screen (`focusIndicatorVisible`)
/// contribute nothing, and nothing dims without a visible focused window
/// (no window to keep lit).
public func focusDimRegions(
    focused: DimWindow?, windows: [DimWindow], frontToBack: [ServerWindow], displays: [CGRect]
) -> [FocusDimDisplay] {
    guard let focused, let focusedIndex = serverIndex(of: focused, in: frontToBack, used: []),
          focusIndicatorVisible(frontToBack[focusedIndex].bounds, on: displays)
    else {
        return []
    }
    let focusedBounds = frontToBack[focusedIndex].bounds
    var used: Set<Int> = [focusedIndex]
    var dimmed: [(bounds: CGRect, rects: [CGRect])] = []
    for window in windows {
        guard let index = serverIndex(of: window, in: frontToBack, used: used) else {
            continue
        }
        used.insert(index)
        let bounds = frontToBack[index].bounds
        guard focusIndicatorVisible(bounds, on: displays) else {
            continue
        }
        var pieces = [bounds]
        for hole in frontToBack[..<index].map(\.bounds) + [focusedBounds] {
            pieces = pieces.flatMap { subtractRect($0, hole) }
        }
        dimmed.append((bounds, pieces))
    }
    return displays.compactMap { display in
        let regions = dimmed.compactMap { entry -> FocusDimWindowRegion? in
            let clipped = entry.rects.map { $0.intersection(display) }
                .filter { !$0.isNull && $0.width >= dimMinimumPiece && $0.height >= dimMinimumPiece }
            return clipped.isEmpty ? nil : FocusDimWindowRegion(bounds: entry.bounds, rects: clipped)
        }
        return regions.isEmpty ? nil : FocusDimDisplay(display: display, windows: regions)
    }
}

/// Why the dim overlay is down (debug log vocabulary).
public enum FocusDimHideReason: String, Equatable, Sendable {
    case disabled
    case motion
    /// SM-08: a snapshot flight draws the dim on its own layers.
    case flight
    case zoom
    case drag
    case noFocus = "no-focus"
    case shutdown
}

/// What the overlays show; the session queue posts it through a
/// `LatestValueMailbox`, the main thread draws it.
public enum FocusDimState: Equatable, Sendable {
    case hidden(FocusDimHideReason)
    case shown(regions: [FocusDimDisplay], strength: Double)

    public var logLine: String {
        switch self {
        case .hidden(let reason):
            return "focus dim hidden reason=\(reason.rawValue)"
        case .shown(let regions, _):
            return "focus dim shown regions=\(regions.reduce(0) { $0 + $1.regionCount })"
        }
    }
}

/// What is going on in the session that keeps the dim down.
public struct FocusDimActivity: Equatable, Sendable {
    /// An AX motion is running.
    public var motion: Bool
    /// A snapshot overlay flight is in the air.
    public var flight: Bool
    /// A native zoom is animating, waiting for its verdict or being verified.
    public var nativeZoom: Bool
    /// A mouse button is down (a drag may be under way).
    public var mouseDown: Bool
    /// A window moved on its own (user drag, app resize) and the snap-back
    /// reflow has not run yet.
    public var dragHeld: Bool

    public init(
        motion: Bool = false, flight: Bool = false, nativeZoom: Bool = false, mouseDown: Bool = false,
        dragHeld: Bool = false
    ) {
        self.motion = motion
        self.flight = flight
        self.nativeZoom = nativeZoom
        self.mouseDown = mouseDown
        self.dragHeld = dragHeld
    }
}

public enum FocusDimDecision: Equatable, Sendable {
    /// Query the WindowServer and show the regions.
    case compute
    /// Hide now; the end of the activity recomputes.
    case hide(FocusDimHideReason)
    /// A button is down: poll again shortly, compute after release.
    case retryAfterRelease
}

/// Pure timing rule: the dim is never visible during motion (AX, or a
/// snapshot flight, whose overlay draws it itself), a native zoom or between
/// a user drag and its snap-back reflow, and never recomputed while a button
/// is down.
public func focusDimDecision(indicator: FocusIndicatorKind, activity: FocusDimActivity) -> FocusDimDecision {
    guard indicator == .dim else {
        return .hide(.disabled)
    }
    if activity.flight {
        return .hide(.flight)
    }
    if activity.motion {
        return .hide(.motion)
    }
    if activity.nativeZoom {
        return .hide(.zoom)
    }
    if activity.dragHeld {
        return .hide(.drag)
    }
    return activity.mouseDown ? .retryAfterRelease : .compute
}

/// Fill opacity: the configured strength clamped to its range, a little
/// lighter in dark mode (dark windows already recede).
public func focusDimAlpha(strength: Double, darkAppearance: Bool) -> Double {
    let range = FocusSectionConfig.dimStrengthRange
    let clamped = min(max(strength, range.lowerBound), range.upperBound)
    return darkAppearance ? clamped * 0.8 : clamped
}

/// Fade in 150 ms at settle, out 80 ms at motion start; none with Reduce
/// Motion. After a snapshot flight (`afterFlight`) the overlay already drew
/// the dim at full strength, so the live one appears in place, no fade.
public func focusDimFadeDuration(showing: Bool, reduceMotion: Bool, afterFlight: Bool = false) -> TimeInterval {
    guard !reduceMotion, !(showing && afterFlight) else {
        return 0
    }
    return showing ? 0.15 : 0.08
}
