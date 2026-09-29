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
    /// Structured form of every failure (kind, requested and actual frame).
    public var failures: [WindowID: ReconcileFailure]
    public var focusChanged: Bool
    public var focusFailed: Bool

    public init(
        applied: [WindowID] = [],
        alreadyCorrect: [WindowID] = [],
        parked: [WindowID] = [],
        vanished: [WindowID] = [],
        failed: [WindowID] = [],
        failureNotes: [WindowID: String] = [:],
        failures: [WindowID: ReconcileFailure] = [:],
        focusChanged: Bool = false,
        focusFailed: Bool = false
    ) {
        self.applied = applied
        self.alreadyCorrect = alreadyCorrect
        self.parked = parked
        self.vanished = vanished
        self.failed = failed
        self.failureNotes = failureNotes
        self.failures = failures
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
    private let motion = MotionBook()
    private var failureGate = FailureLogGate()

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
        case failed(String, ReconcileFailure)
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
                return failed(error, requested: item.desired, actual: nil)
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
                return failed(error, requested: item.desired, actual: actual)
            }
        }

        /// The note stays the error's own text; the structured failure adds
        /// the kind and both frames. A mismatch reports where the window
        /// landed; other kinds report the frame read before the write.
        private func failed(_ error: Error, requested: CGRect, actual: CGRect?) -> WindowOutcome {
            let reporting = error as? FrameFailureReporting
            return .failed(
                String(describing: error),
                ReconcileFailure(
                    kind: reporting?.failureKind ?? "other",
                    requested: requested,
                    actual: reporting?.failureActual ?? actual,
                    detail: reporting == nil ? String(describing: error) : nil
                )
            )
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
        // An animation frame still being written would make its app look
        // busy and fail; let it land first (bounded by the stall timeout).
        waitForMotionIdle(timeout: 0.3)
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
                case .failed(let note, let failure):
                    report.failed.append(id)
                    report.failureNotes[id] = note
                    report.failures[id] = failure
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
                report.failures[id] = ReconcileFailure(
                    kind: "timeout", requested: frames[id] ?? parked[id]?.frame, detail: "app busy"
                )
            case .timedOut, nil:
                report.failed.append(id)
                report.failureNotes[id] = "timeout"
                report.failures[id] = ReconcileFailure(kind: "timeout", requested: frames[id] ?? parked[id]?.frame)
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
        // Routine fast reflows are debug noise; only slow ones surface at info.
        GioLog.record(timing.totalMilliseconds < 16 ? .debug : .info, timing.summaryLine)
        GioLog.record(
            .debug,
            "reconcile applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) vanished=\(report.vanished.count) failed=\(report.failed.count)"
        )
        logFailures(report)
        return report
    }

    /// FI-06: outcome of an immediate focus call.
    public enum FocusNowResult: Equatable, Sendable {
        case focused
        case failed
    }

    /// FI-06: focus one window right now, without waiting for the motion
    /// lanes and without writing any frame. Keyboard focus follows the
    /// logical focus at the start of an animation.
    public func focusNow(_ id: WindowID) -> FocusNowResult {
        do {
            try actuator.focus(id: id)
            return .focused
        } catch {
            return .failed
        }
    }

    /// FI-01: one line per failed window, warn the first time a (window,
    /// kind) pair fails and debug on repeats.
    private func logFailures(_ report: ReconcileReport) {
        for id in report.failed.sorted() {
            guard let failure = report.failures[id] else {
                continue
            }
            let line = reconcileFailureLine(
                id: id, app: appName(id.pid) ?? "pid\(id.pid)", failure: failure
            )
            GioLog.record(failureGate.level(for: id, kind: failure.kind), line)
        }
    }

    /// MO-04 animation frame: written on the app's own lane, position and/or
    /// size only, unverified (the final reconcile verifies). Never blocks and
    /// never queues; false means the app is still busy and the frame is dropped.
    public func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
        guard executor.claim(pid) else {
            return false
        }
        motion.group.enter()
        let worker = MotionWorker(actuator: actuator, clock: clock, appName: appName)
        let executor = executor, motion = motion
        DispatchQueue.global(qos: .userInteractive).async {
            for write in writes {
                worker.write(write, into: motion)
            }
            executor.release(pid)
            motion.group.leave()
        }
        return true
    }

    /// NC-07 / HD-02: put hidden incoming windows just below their target
    /// before a workspace-switch animation. Same lanes and lean write as
    /// motion frames (known origin, unverified), no reads, never focus.
    /// Windows without a known origin in `from` are skipped. Returns the ids
    /// actually written, sorted, so the caller can record them for echo
    /// suppression and update its physical-frame memory.
    @discardableResult
    public func preposition(frames: [WindowID: CGRect], from: [WindowID: CGRect]) -> [WindowID] {
        let known = frames.filter { from[$0.key] != nil }
        guard !known.isEmpty else {
            return []
        }
        waitForMotionIdle(timeout: 0.3)
        let lanes = planWriteLanes(frames: known, parked: [:])
        let actuator = actuator
        let writer = PrepositionWriter(actuator: actuator)
        let results = executor.run(lanes: lanes, mode: concurrency) { item in
            writer.write(item.desired, from: from[item.id]!, for: item.id)
        }
        var written: [WindowID] = []
        for item in lanes.flatMap(\.items).sorted(by: { $0.index < $1.index }) {
            if case .completed(true)? = results[item.index] {
                written.append(item.id)
            }
        }
        return written.sorted()
    }

    /// FI-05: read-only current frames for the render check, one lane per
    /// app so a hung app cannot stall the rest. Vanished or unreadable
    /// windows are absent from the result. Never writes.
    public func currentFrames(of ids: [WindowID]) -> [WindowID: CGRect] {
        guard !ids.isEmpty else {
            return [:]
        }
        let lanes = planWriteLanes(frames: Dictionary(uniqueKeysWithValues: ids.map { ($0, CGRect.zero) }), parked: [:])
        let reader = FrameReader(actuator: actuator)
        let results = executor.run(lanes: lanes, mode: concurrency) { reader.read($0.id) }
        var frames: [WindowID: CGRect] = [:]
        for item in lanes.flatMap(\.items) {
            if case .completed(let frame?)? = results[item.index] {
                frames[item.id] = frame
            }
        }
        return frames
    }

    /// FI-05 corrective nudge: write each window's steps in order (lean,
    /// unverified, each from the previous step) on its app's lane. Returns
    /// the ids whose every step was written, sorted. Never focuses; the
    /// caller bounds it to one nudge per window per settle.
    @discardableResult
    public func nudge(steps: [WindowID: [CGRect]]) -> [WindowID] {
        let known = steps.filter { !$0.value.isEmpty }
        guard !known.isEmpty else {
            return []
        }
        waitForMotionIdle(timeout: 0.3)
        let lanes = planWriteLanes(frames: known.mapValues { $0.last! }, parked: [:])
        let writer = NudgeWriter(actuator: actuator)
        let results = executor.run(lanes: lanes, mode: concurrency) { item in
            writer.write(known[item.id]!, for: item.id)
        }
        var written: [WindowID] = []
        for item in lanes.flatMap(\.items) {
            if case .completed(true)? = results[item.index] {
                written.append(item.id)
            }
        }
        return written.sorted()
    }

    public func waitForMotionIdle(timeout: TimeInterval) {
        _ = motion.group.wait(timeout: .now() + timeout)
    }

    public func takeMotionTimings() -> [WindowWriteTiming] {
        motion.takeTimings()
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

/// Timings and the in-flight marker of motion frames (MO-04).
final class MotionBook: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var timings: [WindowWriteTiming] = []

    func record(_ timing: WindowWriteTiming) {
        lock.withLock { timings.append(timing) }
    }

    func takeTimings() -> [WindowWriteTiming] {
        lock.withLock { defer { timings = [] }; return timings }
    }
}

private struct FrameReader<Actuator: WindowActuator>: @unchecked Sendable {
    let actuator: Actuator

    func read(_ id: WindowID) -> CGRect? {
        (try? actuator.frame(of: id)) ?? nil
    }
}

private struct NudgeWriter<Actuator: WindowActuator>: @unchecked Sendable {
    let actuator: Actuator

    func write(_ steps: [CGRect], for id: WindowID) -> Bool {
        guard var current = (try? actuator.frame(of: id)) ?? nil else {
            return false
        }
        for step in steps {
            guard (try? actuator.setFrame(step, from: current, for: id, verify: false)) != nil else {
                return false
            }
            current = step
        }
        return true
    }
}

private struct PrepositionWriter<Actuator: WindowActuator>: @unchecked Sendable {
    let actuator: Actuator

    func write(_ frame: CGRect, from current: CGRect, for id: WindowID) -> Bool {
        (try? actuator.setFrame(frame, from: current, for: id, verify: false)) != nil
    }
}

private struct MotionWorker<Actuator: WindowActuator>: @unchecked Sendable {
    let actuator: Actuator
    let clock: ReflowClock
    let appName: @Sendable (pid_t) -> String?

    func write(_ write: MotionWrite, into book: MotionBook) {
        let callsBefore = actuator.axCallCount(forPid: write.id.pid)
        let started = clock()
        // A failed frame is not retried: the final reconcile owns correctness.
        try? actuator.setFrame(write.to, from: write.from, for: write.id, verify: false)
        book.record(WindowWriteTiming(
            id: write.id, app: appName(write.id.pid) ?? "pid\(write.id.pid)",
            milliseconds: (clock() - started) * 1000,
            axCalls: actuator.axCallCount(forPid: write.id.pid) - callsBefore
        ))
    }
}

extension WindowReconciler: MotionFrameSink {}

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
