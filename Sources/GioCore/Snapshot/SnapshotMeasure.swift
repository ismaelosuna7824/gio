import CoreGraphics
import Foundation

// SM-02b: pure pieces of the capture latency measurement (Diagnostics) and of
// the ScreenCaptureKit content prefetch. Ids and app names only, never titles.

/// Nearest-rank percentile (`p` in 0...1); 0 for no values.
public func snapshotPercentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else {
        return 0
    }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
}

/// Why a requested window could not even be matched to a ScreenCaptureKit window.
public enum SnapshotUnmatchedReason: String, Equatable, Sendable, CaseIterable {
    /// The WindowServer lists no window at all for the pid.
    case noCGEntryForPid = "no-cg-entry-for-pid"
    /// The pid has windows but none with the managed size.
    case noSizeMatch = "no-same-size-cg-entry"
    /// Several same-size entries and none equals the frame.
    case ambiguousSameSize = "ambiguous-same-size"
    /// Matched a CGWindowID that ScreenCaptureKit does not list.
    case noSCWindow = "no-scwindow-for-cgwindowid"
}

/// The reason a window is unmatched; nil when it matched and ScreenCaptureKit lists it.
public func classifySnapshotMiss(
    pid: pid_t, match: SnapshotMatch, candidates: [SnapshotCandidate], sckWindowIDs: Set<UInt32>
) -> SnapshotUnmatchedReason? {
    switch match {
    case .ambiguous:
        return .ambiguousSameSize
    case .missing:
        return candidates.contains { $0.pid == pid } ? .noSizeMatch : .noCGEntryForPid
    case .matched(let windowID):
        return sckWindowIDs.contains(windowID) ? nil : .noSCWindow
    }
}

/// Latency breakdown of one unbudgeted capture.
public struct SnapshotMeasurement: Equatable, Sendable {
    public let fetchMilliseconds: Double
    public let fetchCached: Bool
    public let windows: Int
    /// One entry per window whose capture finished.
    public let windowMilliseconds: [Double]
    public let backdropMilliseconds: Double?
    public let totalMilliseconds: Double
    public let unmatchedReasons: [SnapshotUnmatchedReason: Int]

    public init(
        fetchMilliseconds: Double, fetchCached: Bool, windows: Int, windowMilliseconds: [Double],
        backdropMilliseconds: Double?, totalMilliseconds: Double,
        unmatchedReasons: [SnapshotUnmatchedReason: Int]
    ) {
        self.fetchMilliseconds = fetchMilliseconds
        self.fetchCached = fetchCached
        self.windows = windows
        self.windowMilliseconds = windowMilliseconds
        self.backdropMilliseconds = backdropMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.unmatchedReasons = unmatchedReasons
    }

    public var captured: Int { windowMilliseconds.count }
    public var p50: Double { snapshotPercentile(windowMilliseconds, 0.5) }
    public var p90: Double { snapshotPercentile(windowMilliseconds, 0.9) }
    public var max: Double { windowMilliseconds.max() ?? 0 }
    public var unmatched: Int { unmatchedReasons.values.reduce(0, +) }

    private var reasonsText: String {
        let parts = unmatchedReasons.filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    private static func ms(_ value: Double) -> String { "\(Int(value.rounded()))ms" }

    private var backdropText: String { backdropMilliseconds.map(Self.ms) ?? "n/a" }

    public var logLine: String {
        "snapshot measure fetch=\(Self.ms(fetchMilliseconds)) cached=\(fetchCached) windows=\(windows) "
            + "captured=\(captured) p50=\(Self.ms(p50)) p90=\(Self.ms(p90)) max=\(Self.ms(max)) "
            + "backdrop=\(backdropText) total=\(Self.ms(totalMilliseconds)) unmatched=\(unmatched) "
            + "reasons=\(reasonsText)"
    }

    /// Multi-line text for the Diagnostics view.
    public var report: String {
        [
            "content fetch: \(Self.ms(fetchMilliseconds)) (\(fetchCached ? "cached" : "refreshed"))",
            "windows: \(windows) requested, \(captured) captured; p50 \(Self.ms(p50)) p90 \(Self.ms(p90)) max \(Self.ms(max))",
            "backdrop: \(backdropText)",
            "total wall: \(Self.ms(totalMilliseconds))",
            "unmatched: \(unmatched)",
            "reasons: \(reasonsText)",
        ].joined(separator: "\n")
    }
}

/// Whether to refresh the ScreenCaptureKit content in the background: at
/// first use and whenever the managed window set changed, so requests on the
/// motion hot path hit the cache instead of paying the fetch inside the budget.
public func shouldPrefetchShareableContent(
    managed: Set<WindowID>, lastPrefetched: Set<WindowID>?, permissionGranted: Bool, inFlight: Bool
) -> Bool {
    guard permissionGranted, !inFlight else {
        return false
    }
    return lastPrefetched != managed
}
