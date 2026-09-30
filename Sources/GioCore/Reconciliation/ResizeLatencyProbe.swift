import CoreGraphics
import Foundation

// Diagnostics: the AX size write can be acknowledged in a few ms while the app
// repaints at the new size much later (new backing surfaces, relayout). The
// probe compares the WindowServer bounds with the requested size until they
// agree; these are its pure decisions (the polling lives in `SessionHost`).

public enum ResizeProbeLimits {
    /// Bounds within this many points of the request count as drawn.
    public static let tolerance: CGFloat = 2
    /// Give up after this many seconds.
    public static let timeout: Double = 1.5
}

public enum ResizeProbeDecision: Equatable, Sendable {
    case pending
    case reached(milliseconds: Int)
    case timeout
}

/// A match wins over the deadline; otherwise the probe keeps polling until
/// `timeout` seconds have elapsed. `observed` is nil when the WindowServer
/// did not list the window.
public func resizeProbeDecision(
    requested: CGSize, observed: CGSize?, elapsed: Double,
    tolerance: CGFloat = ResizeProbeLimits.tolerance, timeout: Double = ResizeProbeLimits.timeout
) -> ResizeProbeDecision {
    if let observed,
       abs(observed.width - requested.width) <= tolerance,
       abs(observed.height - requested.height) <= tolerance {
        return .reached(milliseconds: Int((elapsed * 1000).rounded()))
    }
    return elapsed >= timeout ? .timeout : .pending
}

/// Small per-window memory of the sizes already reached, so a probe can tell
/// the first time a window draws a size from later ones. Bounded in sizes per
/// window and in windows (oldest evicted first).
public struct ResizeSizeHistory: Sendable {
    private let maxSizesPerWindow: Int
    private let maxWindows: Int
    private var sizes: [WindowID: [String]] = [:]
    private var order: [WindowID] = []

    public init(maxSizesPerWindow: Int = 8, maxWindows: Int = 64) {
        self.maxSizesPerWindow = max(1, maxSizesPerWindow)
        self.maxWindows = max(1, maxWindows)
    }

    public var windowCount: Int { sizes.count }

    /// True when `id` had not been recorded at `size` (whole points) yet;
    /// records it either way.
    public mutating func recordIsFirst(_ id: WindowID, size: CGSize) -> Bool {
        let key = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        if sizes[id] == nil {
            if order.count >= maxWindows, let oldest = order.first {
                order.removeFirst()
                sizes[oldest] = nil
            }
            order.append(id)
        }
        var seen = sizes[id] ?? []
        if seen.contains(key) {
            return false
        }
        seen.append(key)
        if seen.count > maxSizesPerWindow {
            seen.removeFirst()
        }
        sizes[id] = seen
        return true
    }
}

/// `resize latency id=<pid:elem> app=<name> requestedSize=WxH wsMs=<ms|timeout> first=<bool>`
public func resizeLatencyLine(
    id: WindowID, app: String, size: CGSize, result: ResizeProbeDecision, first: Bool
) -> String {
    let latency: String
    switch result {
    case .reached(let milliseconds): latency = String(milliseconds)
    case .pending, .timeout: latency = "timeout"
    }
    return "resize latency id=\(id.pid):\(id.elementID) app=\(app) "
        + "requestedSize=\(Int(size.width.rounded()))x\(Int(size.height.rounded())) wsMs=\(latency) first=\(first)"
}
