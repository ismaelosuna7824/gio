import CoreGraphics
import Foundation

// SM-30: live (2026-10-12, 60 fps recordings, after SM-29) every resize
// flight still ended on a stale or flat picture and every hand-off was a hard
// cut. VS Code (Electron) max to half: the flight landed on a 25 s old
// target-size image, then for 2 frames the real window showed its maximized
// layout clipped to the half frame (it had not re-laid out ~370 ms after the
// resize; the SM-29 check reads that as painted), then the right layout.
// Slack first maximize: the whole flight showed the start image beside a huge
// purple box (the SM-27 edge fill sampled Slack's purple frame) although
// Slack had repainted at its new size during the flight.
//
// So: (1) every window whose size changes is captured again at its target
// size during the flight (`SnapshotFreshTracker`), `firstDelay` after its
// write was dispatched, and its layer fades to that fresh image on top; the
// cache keeps it as the window's target-size image. A read the app has not
// repainted for (the WindowServer reports another size, blank, an unpainted
// grown strip, or, when it shrank, the start image cut to the new size:
// `snapshotFreshVerdict`) is retried every `retryInterval` until `limit`;
// after such a read two matching reads are needed (SM-29's rule). (2) The
// fill is the most common colour of the capture's right half
// (`snapshotContentFill`), not its right edge. (3) Resized layers fade out
// over the real windows at the hand-off (`snapshotHandoffFading`), so the
// 1-3 frames an Electron app needs to re-lay out are masked.

/// What a fresh capture needs about one resized window.
public struct SnapshotFreshProbe<Image> {
    /// Target frame (already written), the size it had at the flight start
    /// and its background, as for the SM-29 paint check.
    public let paint: SnapshotPaintProbe
    /// The image its layer started with, when the window shrank: cut to the
    /// new size (`snapshotFreshRegion`) it is what a window that has not
    /// re-laid out shows. Nil for a grow (its grown strips tell).
    public let start: SnapshotFace<Image>?
    /// The cached image of the target size, if any: a read matching it is
    /// right whatever the stale test says.
    public let cached: SnapshotFace<Image>?

    public init(paint: SnapshotPaintProbe, start: SnapshotFace<Image>? = nil, cached: SnapshotFace<Image>? = nil) {
        self.paint = paint
        self.start = start
        self.cached = cached
    }
}

extension SnapshotFreshProbe: @unchecked Sendable {}

/// One fresh capture of one window at its target size (full resolution).
public struct SnapshotFreshRead<Image> {
    public let image: Image
    /// `snapshotContentFill` of the capture.
    public let fill: ThemeColor?
    /// The size the WindowServer reports for the window, nil when unknown.
    public let windowSize: CGSize?
    /// The SM-29 verdict of the capture (size, blank and grown-strip tests).
    public let paint: SnapshotPaintVerdict
    /// Sparse samples of the capture (`snapshotPaintStable`).
    public let samples: [UInt32]
    /// Sparse samples of `snapshotFreshRegion` in the start image and in
    /// the capture; nil when the window did not shrink.
    public let startRegion: [UInt32]?
    public let freshRegion: [UInt32]?
    /// Sparse samples of the cached target-size image, nil without one.
    public let cached: [UInt32]?

    public init(
        image: Image, fill: ThemeColor?, windowSize: CGSize?, paint: SnapshotPaintVerdict, samples: [UInt32],
        startRegion: [UInt32]? = nil, freshRegion: [UInt32]? = nil, cached: [UInt32]? = nil
    ) {
        self.image = image
        self.fill = fill
        self.windowSize = windowSize
        self.paint = paint
        self.samples = samples
        self.startRegion = startRegion
        self.freshRegion = freshRegion
        self.cached = cached
    }
}

extension SnapshotFreshRead: @unchecked Sendable {}

/// The top-left part both sizes share, when the window shrank in either
/// direction by more than `tolerance`: a window that has not re-laid out yet
/// shows exactly that part of its start image. Nil for a grow.
public func snapshotFreshRegion(start: CGSize, target: CGSize, tolerance: CGFloat = 1) -> CGSize? {
    guard target.width < start.width - tolerance || target.height < start.height - tolerance else {
        return nil
    }
    return CGSize(width: min(start.width, target.width), height: min(start.height, target.height))
}

/// `region` (points, from the top-left corner) in the pixels of an image of
/// `size` points captured at `pixelWidth` x `pixelHeight` (top-left origin).
public func snapshotRegionPixels(_ region: CGSize, of size: CGSize, pixelWidth: Int, pixelHeight: Int) -> CGRect {
    guard size.width > 0, size.height > 0 else {
        return .zero
    }
    let width = (CGFloat(pixelWidth) * min(region.width / size.width, 1)).rounded()
    let height = (CGFloat(pixelHeight) * min(region.height / size.height, 1)).rounded()
    return CGRect(x: 0, y: 0, width: width, height: height)
}

/// What one fresh read shows.
public enum SnapshotFreshVerdict: String, Equatable, Sendable {
    /// The window at its target size, re-laid out: the layer may show it.
    case fresh
    /// Not at the target size yet, or a grown strip unpainted.
    case partial
    case blank
    /// Painted, but still its old layout clipped to the new frame.
    case stale
    /// Not matched or not captured.
    case unknown
}

/// The verdict of `read` (nil: no match or no capture) of a window landing
/// at `target` size. A window the WindowServer reports at another size would
/// be captured scaled: partial. Then the SM-29 verdict; a painted read that
/// matches the cached target image is fresh; one that matches the start
/// image cut to the new size is stale.
public func snapshotFreshVerdict<Image>(_ read: SnapshotFreshRead<Image>?, target: CGSize) -> SnapshotFreshVerdict {
    guard let read else {
        return .unknown
    }
    if let size = read.windowSize, snapshotResized(from: size, to: target, tolerance: 2) {
        return .partial
    }
    switch read.paint {
    case .unknown:
        return .unknown
    case .blank:
        return .blank
    case .partial:
        return .partial
    case .painted:
        break
    }
    if let cached = read.cached, snapshotPaintStable(cached, read.samples) {
        return .fresh
    }
    if let start = read.startRegion, let fresh = read.freshRegion, snapshotPaintStable(start, fresh) {
        return .stale
    }
    return .fresh
}

/// How a window's fresh captures went: when one was shown (milliseconds
/// after its write; nil: none), how many captures ran and the last verdict.
public struct SnapshotFreshOutcome: Equatable, Sendable {
    public let milliseconds: Int?
    public let attempts: Int
    public let last: SnapshotFreshVerdict?

    public init(milliseconds: Int?, attempts: Int, last: SnapshotFreshVerdict?) {
        self.milliseconds = milliseconds
        self.attempts = attempts
        self.last = last
    }
}

/// The fresh captures of the resized windows of one flight. `start` begins
/// a series when a window's write at a new size is dispatched (a running
/// series of that window is superseded); its first capture runs
/// `firstDelay` later. Each answer (`record`) applies the read, retries
/// after `retryInterval` or stops; no capture starts past `limit` after the
/// write. One capture at a time per window. Tokens never repeat, so an
/// answer of a superseded series or of an earlier flight is dropped.
public struct SnapshotFreshTracker: Equatable, Sendable {
    /// After the write: a native app has repainted by then and the capture
    /// (~60-150 ms live) still lands inside a ~350 ms Alt+F.
    public static let firstDelay: TimeInterval = 0.12
    public static let retryInterval: TimeInterval = 0.04
    /// The overlay is gone by then (flight ~350-400 ms plus the SM-29 hold).
    public static let limit: TimeInterval = 0.6

    public enum Step: Equatable, Sendable {
        /// Show the read and keep it in the cache; the series is done.
        case apply
        case retry(after: TimeInterval)
        /// The limit is reached without a read to show.
        case stop
    }

    private struct Series: Equatable, Sendable {
        let token: Int
        let startedAt: TimeInterval
        var attempts = 0
        /// Caught repainting (partial, blank or stale): a fresh read must
        /// match the previous one.
        var repainting = false
        var previous: [UInt32]?
        var last: SnapshotFreshVerdict?
        var appliedAfter: TimeInterval?
        var done = false
    }

    private var counter = 0
    private var series: [WindowID: Series] = [:]

    public init() {}

    /// A new series for `id`, whose write was dispatched at `now`: its token.
    public mutating func start(_ id: WindowID, now: TimeInterval) -> Int {
        counter += 1
        series[id] = Series(token: counter, startedAt: now)
        return counter
    }

    /// The capture of `token` starts: false when superseded or done.
    public mutating func capture(_ id: WindowID, token: Int) -> Bool {
        guard var current = series[id], current.token == token, !current.done else {
            return false
        }
        current.attempts += 1
        series[id] = current
        return true
    }

    /// The capture of `token` read `verdict` (`samples`: its sparse
    /// samples) at `now`. Nil when superseded or done.
    public mutating func record(
        _ id: WindowID, token: Int, verdict: SnapshotFreshVerdict, samples: [UInt32], now: TimeInterval
    ) -> Step? {
        guard var current = series[id], current.token == token, !current.done else {
            return nil
        }
        current.last = verdict
        let elapsed = now - current.startedAt
        switch verdict {
        case .fresh:
            if !current.repainting || current.previous.map({ snapshotPaintStable($0, samples) }) == true {
                current.done = true
                current.appliedAfter = elapsed
                series[id] = current
                return .apply
            }
            current.previous = samples
        case .partial, .blank, .stale:
            current.repainting = true
            current.previous = nil
        case .unknown:
            break
        }
        guard elapsed + Self.retryInterval <= Self.limit + 1e-9 else {
            current.done = true
            series[id] = current
            return .stop
        }
        series[id] = current
        return .retry(after: Self.retryInterval)
    }

    /// `id`'s series no longer applies (its size is back to the start one).
    public mutating func forget(_ id: WindowID) {
        series.removeValue(forKey: id)
    }

    /// The flight is over: every series stops (tokens keep counting).
    public mutating func removeAll() {
        series.removeAll()
    }

    public func outcome(_ id: WindowID) -> SnapshotFreshOutcome? {
        series[id].map { current in
            SnapshotFreshOutcome(
                milliseconds: current.appliedAfter.map { Int(($0 * 1000).rounded()) }, attempts: current.attempts,
                last: current.last
            )
        }
    }
}

/// `snapshot resize id=P:E mode=<mode> fresh=<ms|none> attempts=N
/// [last=<verdict>]`, debug, at the hand-off: how the layer resized and
/// when its fresh image came (or the last verdict when none did).
public func snapshotResizeOutcomeLine(_ id: WindowID, mode: SnapshotResizeMode, fresh: SnapshotFreshOutcome) -> String {
    var line = "snapshot resize id=\(id.pid):\(id.elementID) mode=\(mode.rawValue) "
    if let milliseconds = fresh.milliseconds {
        line += "fresh=\(milliseconds) attempts=\(fresh.attempts)"
    } else {
        line += "fresh=none attempts=\(fresh.attempts)"
        if let last = fresh.last {
            line += " last=\(last.rawValue)"
        }
    }
    return line
}

/// How long a resized window's layer fades out over the real window at the
/// hand-off. The mismatch after a resize lasts 1-3 frames (live, Electron);
/// eased in and out, the layer is still ~85 % opaque after two frames.
public let snapshotHandoffFadeDuration: TimeInterval = 0.12

/// The layers that fade out at the hand-off: the windows that changed size
/// and fly with a layer. Pure moves (and windows shown through holes) leave
/// at once, as before.
public func snapshotHandoffFading(resized: Set<WindowID>, layered: Set<WindowID>) -> Set<WindowID> {
    resized.intersection(layered)
}
