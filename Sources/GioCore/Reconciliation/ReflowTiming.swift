import Foundation

/// MO-01: monotonic seconds, injectable so timing tests are deterministic.
public typealias ReflowClock = @Sendable () -> TimeInterval

/// Default clock: monotonic system uptime (immune to wall-clock jumps).
public let systemReflowClock: ReflowClock = { ProcessInfo.processInfo.systemUptime }

/// What one window cost inside a reflow: wall time of everything the
/// reconciler did for it (diff read, write, verify) and the Accessibility
/// calls the actuator reported for its process meanwhile.
public struct WindowWriteTiming: Equatable, Sendable {
    public let id: WindowID
    public let app: String
    public let milliseconds: Double
    public let axCalls: Int

    public init(id: WindowID, app: String, milliseconds: Double, axCalls: Int) {
        self.id = id
        self.app = app
        self.milliseconds = milliseconds
        self.axCalls = axCalls
    }
}

/// Measurements of one `reconcile` pass. IDs and app names only — never
/// window titles.
public struct ReflowTiming: Equatable, Sendable {
    /// Windows slower than this are logged individually at debug.
    public static let slowWindowMilliseconds: Double = 20

    public var totalMilliseconds: Double
    public var focusMilliseconds: Double
    /// Deterministic order (same as the report: parked first, then visible).
    public var windows: [WindowWriteTiming]
    public var focusAXCalls: Int

    public init(
        totalMilliseconds: Double, focusMilliseconds: Double = 0,
        windows: [WindowWriteTiming], focusAXCalls: Int = 0
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.focusMilliseconds = focusMilliseconds
        self.windows = windows
        self.focusAXCalls = focusAXCalls
    }

    public var axCalls: Int {
        windows.reduce(focusAXCalls) { $0 + $1.axCalls }
    }

    /// The app whose windows cost the most time together (ties: lowest pid).
    public var slowestApp: (app: String, milliseconds: Double)? {
        var perPid: [pid_t: (app: String, milliseconds: Double)] = [:]
        for window in windows {
            let entry = perPid[window.id.pid] ?? (window.app, 0)
            perPid[window.id.pid] = (entry.app, entry.milliseconds + window.milliseconds)
        }
        return perPid.keys.sorted()
            .compactMap { perPid[$0] }
            .reduce(nil as (app: String, milliseconds: Double)?) { best, next in
                guard let best else { return next }
                return next.milliseconds > best.milliseconds ? next : best
            }
    }

    /// `reflow timing total=Xms windows=N axCalls=M slowest=<app> Yms focus=Zms`
    public var summaryLine: String {
        let slowest = slowestApp.map { "\($0.app) \(Self.format($0.milliseconds))ms" } ?? "none"
        return "reflow timing total=\(Self.format(totalMilliseconds))ms windows=\(windows.count) "
            + "axCalls=\(axCalls) slowest=\(slowest) focus=\(Self.format(focusMilliseconds))ms"
    }

    /// One debug line per window slower than the threshold.
    public var slowWindowLines: [String] {
        windows.filter { $0.milliseconds > Self.slowWindowMilliseconds }.map {
            "reflow slow window=\($0.id.pid):\($0.id.elementID) app=\($0.app) "
                + "\(Self.format($0.milliseconds))ms axCalls=\($0.axCalls)"
        }
    }

    private static func format(_ milliseconds: Double) -> String {
        String(Int(milliseconds.rounded()))
    }
}
