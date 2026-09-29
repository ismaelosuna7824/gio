import CoreGraphics
import Foundation

/// Plan §14 actuator: the physical side of reconciliation. Implementations
/// live in adapter layers (GioMacOS); this protocol keeps `GioCore`
/// macOS-free. `frame(of:)` returns nil for vanished windows — absence is
/// data, never an error.
public protocol WindowActuator: AnyObject {
    func frame(of id: WindowID) throws -> CGRect?
    func setFrame(_ frame: CGRect, for id: WindowID) throws
    func focus(id: WindowID) throws
    /// Cumulative Accessibility calls issued for windows of `pid`. Optional
    /// instrumentation (MO-01): the default reports 0.
    func axCallCount(forPid pid: pid_t) -> Int
    /// Hot-path write (MO-02): the caller already read `current` this pass,
    /// so the implementation must not read it again, and `verify == false`
    /// (parked windows, whose clamped landing is accepted anyway) skips the
    /// blocking read-back. The default forwards to the plain `setFrame`.
    func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws
}

public extension WindowActuator {
    func axCallCount(forPid pid: pid_t) -> Int { 0 }

    func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
        try setFrame(frame, for: id)
    }
}

/// What one `reconcile` pass did, in deterministic (sorted) order.
/// Failures are recorded by ID and never abort the batch: every other
/// window is still attempted. Underlying causes stay with the actuator
/// layer, which can log its typed errors; this report is the honest,
/// sendable outcome.
public struct ReconcileReport: Equatable, Sendable {
    public var applied: [WindowID]
    public var alreadyCorrect: [WindowID]
    /// Off-viewport windows written to their parking spot (already-parked
    /// ones count as `alreadyCorrect`).
    public var parked: [WindowID]
    public var vanished: [WindowID]
    public var failed: [WindowID]
    /// First error description per failed window, so live retests report
    /// causes instead of bare IDs. Deterministic: sorted by ID on read.
    public var failureNotes: [WindowID: String]
    public var focusChanged: Bool
    public var focusFailed: Bool

    public init(
        applied: [WindowID] = [],
        alreadyCorrect: [WindowID] = [],
        parked: [WindowID] = [],
        vanished: [WindowID] = [],
        failed: [WindowID] = [],
        failureNotes: [WindowID: String] = [:],
        focusChanged: Bool = false,
        focusFailed: Bool = false
    ) {
        self.applied = applied
        self.alreadyCorrect = alreadyCorrect
        self.parked = parked
        self.vanished = vanished
        self.failed = failed
        self.failureNotes = failureNotes
        self.focusChanged = focusChanged
        self.focusFailed = focusFailed
    }

    /// Deterministic first failure for display.
    public var firstFailure: String? {
        failureNotes.keys.sorted().first.flatMap { failureNotes[$0] }
    }
}

/// Plan §14: the ONLY component authorized to physically modify windows.
/// Desired state in, minimal writes out: frames within `tolerance` are
/// skipped, vanished windows are recorded, and focus is applied last so the
/// target keeps it. Pure `GioCore` — test with a mock actuator.
public final class WindowReconciler<Actuator: WindowActuator> {
    private let actuator: Actuator
    private let tolerance: CGFloat
    private let clock: ReflowClock
    private let appName: @Sendable (pid_t) -> String?
    private let concurrency: LaneConcurrency
    private let executor = LaneExecutor()

    /// Timing of the most recent `reconcile` pass (MO-01).
    public private(set) var lastTiming: ReflowTiming?

    /// Keep one reconciler alive across reflows: it remembers which apps are
    /// still stuck in an abandoned lane (MO-03).
    public init(
        actuator: Actuator, tolerance: CGFloat = 1,
        concurrency: LaneConcurrency = .concurrent(stallTimeout: 0.25),
        clock: @escaping ReflowClock = systemReflowClock,
        appName: @escaping @Sendable (pid_t) -> String? = { _ in nil }
    ) {
        self.actuator = actuator
        self.tolerance = tolerance
        self.concurrency = concurrency
        self.clock = clock
        self.appName = appName
    }

    /// What happened to one window; folded into the report in serial order.
    private enum WindowOutcome: Sendable {
        case alreadyCorrect
        case vanished
        case failed(String)
        case applied
        case parkedApplied(clamped: Bool)
    }

    private struct ItemResult: Sendable {
        let outcome: WindowOutcome
        let timing: WindowWriteTiming
    }

    /// Everything a lane thread needs, detached from the reconciler.
    private struct LaneWorker: @unchecked Sendable {
        let actuator: Actuator
        let tolerance: CGFloat
        let clock: ReflowClock
        let appName: @Sendable (pid_t) -> String?

        func process(_ item: WriteItem) -> ItemResult {
            let callsBefore = actuator.axCallCount(forPid: item.id.pid)
            let started = clock()
            let outcome = reconcileOne(item)
            return ItemResult(
                outcome: outcome,
                timing: WindowWriteTiming(
                    id: item.id, app: appName(item.id.pid) ?? "pid\(item.id.pid)",
                    milliseconds: (clock() - started) * 1000,
                    axCalls: actuator.axCallCount(forPid: item.id.pid) - callsBefore
                )
            )
        }

        private func reconcileOne(_ item: WriteItem) -> WindowOutcome {
            let id = item.id
            let actual: CGRect?
            do {
                actual = try actuator.frame(of: id)
            } catch {
                return .failed(String(describing: error))
            }
            guard let actual else {
                return .vanished
            }
            if matches(item.desired, actual) || item.parked.map({ isParked(actual, $0, tolerance) }) == true {
                return .alreadyCorrect
            }
            do {
                try actuator.setFrame(item.desired, from: actual, for: id, verify: item.parked == nil)
                return item.parked == nil ? .applied : .parkedApplied(clamped: false)
            } catch {
                // macOS may clamp a parked position; accept a landing that is
                // still parked (size kept, small strip on the intended side).
                if let parked = item.parked, let landed = try? actuator.frame(of: id),
                   isParked(landed, parked, tolerance)
                {
                    return .parkedApplied(clamped: true)
                }
                return .failed(String(describing: error))
            }
        }

        private func matches(_ requested: CGRect, _ actual: CGRect) -> Bool {
            abs(requested.origin.x - actual.origin.x) <= tolerance
                && abs(requested.origin.y - actual.origin.y) <= tolerance
                && abs(requested.size.width - actual.size.width) <= tolerance
                && abs(requested.size.height - actual.size.height) <= tolerance
        }
    }

    /// Windows are grouped by app; each app's writes run serially on their
    /// own lane (parked before visible, never focused) and lanes run
    /// concurrently. A parked write counts as done when the window keeps its
    /// size and only a small strip stays on the intended side, because macOS
    /// may clamp the position. Focus is applied last, after every lane.
    @discardableResult
    public func reconcile(
        frames: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget] = [:],
        focused: WindowID?,
        currentlyFocused: WindowID?
    ) -> ReconcileReport {
        var report = ReconcileReport()
        let started = clock()
        let lanes = planWriteLanes(frames: frames, parked: parked)
        let worker = LaneWorker(actuator: actuator, tolerance: tolerance, clock: clock, appName: appName)
        let results = executor.run(lanes: lanes, mode: concurrency) { worker.process($0) }
        var windowTimings: [WindowWriteTiming] = []
        let stallMilliseconds: Double
        if case .concurrent(let stall) = concurrency {
            stallMilliseconds = stall * 1000
        } else {
            stallMilliseconds = 0
        }
        for item in lanes.flatMap(\.items).sorted(by: { $0.index < $1.index }) {
            let id = item.id
            switch results[item.index] {
            case .completed(let result):
                windowTimings.append(result.timing)
                switch result.outcome {
                case .alreadyCorrect:
                    report.alreadyCorrect.append(id)
                case .vanished:
                    report.vanished.append(id)
                case .failed(let note):
                    report.failed.append(id)
                    report.failureNotes[id] = note
                case .applied:
                    report.applied.append(id)
                case .parkedApplied(let clamped):
                    if clamped {
                        GioLog.record(.debug, "parked clamped id=\(id.pid):\(id.elementID)")
                    }
                    report.parked.append(id)
                }
            case .skippedBusy:
                report.failed.append(id)
                report.failureNotes[id] = "timeout (previous write to this app still pending)"
            case .timedOut, nil:
                report.failed.append(id)
                report.failureNotes[id] = "timeout"
                windowTimings.append(WindowWriteTiming(
                    id: id, app: appName(id.pid) ?? "pid\(id.pid)",
                    milliseconds: stallMilliseconds, axCalls: 0
                ))
            }
        }
        var focusMilliseconds = 0.0
        var focusCalls = 0
        if let focused, focused != currentlyFocused, parked[focused] == nil {
            let callsBefore = actuator.axCallCount(forPid: focused.pid)
            let focusStart = clock()
            do {
                try actuator.focus(id: focused)
                report.focusChanged = true
            } catch {
                report.focusFailed = true
            }
            focusMilliseconds = (clock() - focusStart) * 1000
            focusCalls = actuator.axCallCount(forPid: focused.pid) - callsBefore
        }
        let timing = ReflowTiming(
            totalMilliseconds: (clock() - started) * 1000, focusMilliseconds: focusMilliseconds,
            windows: windowTimings, focusAXCalls: focusCalls
        )
        lastTiming = timing
        for line in timing.slowWindowLines {
            GioLog.record(.debug, line)
        }
        GioLog.record(.info, timing.summaryLine)
        GioLog.record(
            .debug,
            "reconcile applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) vanished=\(report.vanished.count) failed=\(report.failed.count)"
        )
        if !report.failed.isEmpty {
            GioLog.record(.warn, "reconcile failures persist; see firstFailure in tile report")
        }
        return report
    }

    /// Gio is leaving: bring every listed window that is parked or off-screen
    /// back inside its display (see `planRestore`). Windows already on
    /// screen are not written. Never focuses; vanished windows are recorded.
    @discardableResult
    public func restoreOffscreen(ids: [WindowID], displays: [RestoreDisplay]) -> ReconcileReport {
        var report = ReconcileReport()
        var current: [WindowID: CGRect] = [:]
        for id in ids.sorted() {
            do {
                if let frame = try actuator.frame(of: id) {
                    current[id] = frame
                } else {
                    report.vanished.append(id)
                }
            } catch {
                report.failed.append(id)
                report.failureNotes[id] = String(describing: error)
            }
        }
        let plan = planRestore(windows: current, displays: displays)
        for id in plan.keys.sorted() {
            do {
                try actuator.setFrame(plan[id]!, for: id)
                report.applied.append(id)
            } catch {
                // A clamped landing that is now on screen still counts.
                if let landed = try? actuator.frame(of: id),
                   planRestore(windows: [id: landed], displays: displays).isEmpty
                {
                    report.applied.append(id)
                } else {
                    report.failed.append(id)
                    report.failureNotes[id] = String(describing: error)
                }
            }
        }
        GioLog.record(
            .info,
            "restore applied=\(report.applied.count) vanished=\(report.vanished.count) failed=\(report.failed.count)"
        )
        return report
    }

    /// Largest strip of a parked window allowed inside its display.
    public static var maxParkedStrip: CGFloat { parkedStripLimit }
}

let parkedStripLimit: CGFloat = 40

func isParked(_ actual: CGRect, _ target: ParkedTarget, _ tolerance: CGFloat) -> Bool {
    guard abs(actual.width - target.frame.width) <= tolerance,
          abs(actual.height - target.frame.height) <= tolerance
    else {
        return false
    }
    let inside = actual.intersection(target.display)
    let strip = parkedStripLimit
    let visibleWidth = inside.isNull ? 0 : inside.width
    let visibleHeight = inside.isNull ? 0 : inside.height
    switch target.edge {
    case .left:
        return actual.minX < target.display.minX && visibleWidth <= strip
    case .right:
        return actual.maxX > target.display.maxX && visibleWidth <= strip
    case .corner:
        return visibleWidth <= strip && visibleHeight <= strip
    }
}
