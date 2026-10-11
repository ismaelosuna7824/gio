import Foundation

/// TG-03: whether trackpad gestures run, and why (log-safe).
public struct GestureSourceStatus: Equatable, Sendable {
    public var available: Bool
    public var reason: String

    public init(available: Bool, reason: String) {
        self.available = available
        self.reason = reason
    }
}

/// `missingSymbols` nil: MultitouchSupport was not loaded yet. A missing
/// private symbol wins over everything (gestures cannot run on this macOS),
/// then `[gestures]` with every gesture off, then no multitouch device.
public func gestureSourceStatus(enabled: Bool, missingSymbols: [String]?, devices: Int) -> GestureSourceStatus {
    guard let missingSymbols else {
        return GestureSourceStatus(available: false, reason: "not-loaded")
    }
    guard missingSymbols.isEmpty else {
        return GestureSourceStatus(available: false, reason: "missing-symbols:" + missingSymbols.joined(separator: ","))
    }
    guard enabled else {
        return GestureSourceStatus(available: false, reason: "config-off")
    }
    guard devices > 0 else {
        return GestureSourceStatus(available: false, reason: "no-trackpad")
    }
    return GestureSourceStatus(available: true, reason: "devices=\(devices)")
}

/// `gestures available=<bool> reason=<reason>` once, then on change.
public struct GestureStatusLogGate: Sendable {
    private var last: GestureSourceStatus?

    public init() {}

    public mutating func line(for status: GestureSourceStatus) -> String? {
        guard status != last else {
            return nil
        }
        last = status
        return "gestures available=\(status.available) reason=\(status.reason)"
    }
}
