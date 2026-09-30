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
    /// Whether `axCallCount` is maintained. Counting costs a lock per AX
    /// call, so an actuator may turn it off (debug logging only); timing then
    /// reports 0 calls and the counter is not even read. Default: true.
    var tracksCalls: Bool { get }
    /// Whether the window's own zoom (the double-click on the title bar) can
    /// be triggered. Default: unsupported.
    func zoomAvailability(of id: WindowID) -> ZoomAvailability
    /// Trigger the window's own zoom (a toggle). It writes no frame; the app
    /// animates in-process. Default: unsupported.
    func pressZoom(id: WindowID) -> ZoomPressResult
}

public extension WindowActuator {
    func axCallCount(forPid pid: pid_t) -> Int { 0 }
    var tracksCalls: Bool { true }
    func zoomAvailability(of id: WindowID) -> ZoomAvailability { .unavailable("unsupported") }
    func pressZoom(id: WindowID) -> ZoomPressResult { .unavailable("unsupported") }

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
    /// PA-04 diagnostics, not part of equality: windows whose AX read was
    /// skipped because their frame was trusted, and the frame each visible
    /// or read window is known to sit at after the pass (read, verified by
    /// the write, or trusted). Failed and vanished windows have none.
    public var skippedReads: Int = 0
    public var settledFrames: [WindowID: CGRect] = [:]

    public static func == (lhs: ReconcileReport, rhs: ReconcileReport) -> Bool {
        lhs.applied == rhs.applied && lhs.alreadyCorrect == rhs.alreadyCorrect && lhs.parked == rhs.parked
            && lhs.vanished == rhs.vanished && lhs.failed == rhs.failed
            && lhs.failureNotes == rhs.failureNotes && lhs.failures == rhs.failures
            && lhs.focusChanged == rhs.focusChanged && lhs.focusFailed == rhs.focusFailed
    }

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
    private let names: AppNameCache
    private let concurrency: LaneConcurrency
    private let executor: LaneExecutor
    private let motion: MotionBook
    private let motionLanes: MotionLanes
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
        self.names = AppNameCache(resolve: appName)
        let executor = LaneExecutor()
        let motion = MotionBook()
        let worker = MotionWorker(actuator: actuator, clock: clock)
        self.executor = executor
        self.motion = motion
        motionLanes = MotionLanes(executor: executor, book: motion) { worker.write($0, into: motion) }
    }

    /// What happened to one window; folded into the report in serial order.
    private enum WindowOutcome: Sendable {
        case alreadyCorrect(CGRect)
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

        /// The timing carries no app name: names are resolved once per pid
        /// when the report is folded, never per write.
        func process(_ item: WriteItem) -> ItemResult {
            let tracks = actuator.tracksCalls
            let callsBefore = tracks ? actuator.axCallCount(forPid: item.id.pid) : 0
            let started = clock()
            let outcome = reconcileOne(item)
            return ItemResult(
                outcome: outcome,
                timing: WindowWriteTiming(
                    id: item.id, app: "",
                    milliseconds: (clock() - started) * 1000,
                    axCalls: tracks ? actuator.axCallCount(forPid: item.id.pid) - callsBefore : 0
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
                return .alreadyCorrect(actual)
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
        currentlyFocused: WindowID?,
        trusted: TrustedFrames = TrustedFrames()
    ) -> ReconcileReport {
        var report = ReconcileReport()
        // An animation frame still being written would make its app look
        // busy and fail; let it land first (bounded by the stall timeout).
        waitForMotionIdle(timeout: 0.3)
        let started = clock()
        // PA-04: a window sitting at a frame Gio placed and verified needs
        // neither the two AX reads nor a write. Windows that moved in this
        // motion are not trusted by the caller, so they are still verified.
        var skipped: [WindowID] = []
        var toWrite = frames
        var toPark = parked
        if trusted.count > 0 {
            for (id, target) in parked where trusted.canSkipRead(id, desired: target.frame) {
                skipped.append(id)
                toPark.removeValue(forKey: id)
                report.settledFrames[id] = target.frame
            }
            for (id, frame) in frames where parked[id] == nil && trusted.canSkipRead(id, desired: frame) {
                skipped.append(id)
                toWrite.removeValue(forKey: id)
                report.settledFrames[id] = frame
            }
            skipped.sort()
            report.alreadyCorrect.append(contentsOf: skipped)
            report.skippedReads = skipped.count
        }
        let lanes = planWriteLanes(frames: toWrite, parked: toPark)
        let worker = LaneWorker(actuator: actuator, tolerance: tolerance, clock: clock)
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
                windowTimings.append(result.timing.named(names.display(id.pid)))
                switch result.outcome {
                case .alreadyCorrect(let actual):
                    report.alreadyCorrect.append(id)
                    report.settledFrames[id] = actual
                case .vanished:
                    report.vanished.append(id)
                case .failed(let note, let failure):
                    report.failed.append(id)
                    report.failureNotes[id] = note
                    report.failures[id] = failure
                case .applied:
                    report.applied.append(id)
                    report.settledFrames[id] = item.desired
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
                    id: id, app: names.display(id.pid),
                    milliseconds: stallMilliseconds, axCalls: 0
                ))
            }
        }
        var focusMilliseconds = 0.0
        var focusCalls = 0
        if let focused, focused != currentlyFocused, parked[focused] == nil {
            let tracks = actuator.tracksCalls
            let callsBefore = tracks ? actuator.axCallCount(forPid: focused.pid) : 0
            let focusStart = clock()
            do {
                try actuator.focus(id: focused)
                report.focusChanged = true
            } catch {
                report.focusFailed = true
            }
            focusMilliseconds = (clock() - focusStart) * 1000
            focusCalls = tracks ? actuator.axCallCount(forPid: focused.pid) - callsBefore : 0
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
            "reconcile applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) skippedReads=\(report.skippedReads) vanished=\(report.vanished.count) failed=\(report.failed.count)"
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
                id: id, app: names.display(id.pid), failure: failure
            )
            GioLog.record(failureGate.level(for: id, kind: failure.kind), line)
        }
    }

    /// MO-04 animation frame (PA-05): stored as the latest pending frame of
    /// the app's persistent lane, written position and/or size only,
    /// unverified (the final reconcile verifies). Never blocks. A frame the
    /// lane has not started yet is overwritten by a newer one (counted as a
    /// drop); false means an abandoned reconcile lane still holds the app.
    public func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
        motionLanes.submit(pid: pid, writes: writes)
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

    /// Native zoom: whether `id`'s app can zoom the window, asked on the app's
    /// own lane like every other window operation. A lane that stalls reads as
    /// unavailable.
    public func zoomAvailability(of id: WindowID) -> ZoomAvailability {
        runZoomOperation(on: id, timedOut: .unavailable("timeout")) { $0.zoomAvailability(of: id) }
    }

    /// Native zoom: trigger `id`'s own zoom on the app's lane. The only path
    /// for this AX action; it writes no frame, so the caller marks the window
    /// mid-zoom and never writes it until the zoom settled.
    public func pressZoom(_ id: WindowID) -> ZoomPressResult {
        runZoomOperation(on: id, timedOut: .unavailable("timeout")) { $0.pressZoom(id: id) }
    }

    private func runZoomOperation<Value: Sendable>(
        on id: WindowID, timedOut: Value, _ operation: @escaping @Sendable (Actuator) -> Value
    ) -> Value {
        let lanes = planWriteLanes(frames: [id: .zero], parked: [:])
        let actuator = actuator
        let box = UncheckedSendableBox(actuator)
        let results = executor.run(lanes: lanes, mode: concurrency) { _ in operation(box.value) }
        if case .completed(let value)? = results[0] {
            return value
        }
        return timedOut
    }

    /// Bounded wait for the in-flight motion writes; frames still pending
    /// after the timeout are discarded (see `MotionLanes.waitForIdle`).
    public func waitForMotionIdle(timeout: TimeInterval) {
        motionLanes.waitForIdle(timeout: timeout)
    }

    var motionLaneCount: Int { motionLanes.count }

    func motionLaneIdentity(pid: pid_t) -> AnyObject? {
        motionLanes.lane(pid: pid)
    }

    /// Per-app motion write stats accumulated since the last call.
    public func takeMotionStats() -> [pid_t: MotionWriteStats] {
        motion.takeStats()
    }

    /// The app is gone: drop what is cached for its pid.
    public func forgetApp(pid: pid_t) {
        names.forget(pid)
        motionLanes.forget(pid: pid)
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

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Aggregated timings of motion frames (MO-04).
final class MotionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: [pid_t: MotionWriteStats] = [:]

    func record(pid: pid_t, milliseconds: Double, axCalls: Int) {
        lock.withLock { stats[pid, default: MotionWriteStats()].add(milliseconds: milliseconds, axCalls: axCalls) }
    }

    func recordDrop(pid: pid_t) {
        lock.withLock { stats[pid, default: MotionWriteStats()].drops += 1 }
    }

    func takeStats() -> [pid_t: MotionWriteStats] {
        lock.withLock { defer { stats = [:] }; return stats }
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

    func write(_ write: MotionWrite, into book: MotionBook) {
        let pid = write.id.pid
        let tracks = actuator.tracksCalls
        let callsBefore = tracks ? actuator.axCallCount(forPid: pid) : 0
        let started = clock()
        // A failed frame is not retried: the final reconcile owns correctness.
        try? actuator.setFrame(write.to, from: write.from, for: write.id, verify: false)
        book.record(
            pid: pid, milliseconds: (clock() - started) * 1000,
            axCalls: tracks ? actuator.axCallCount(forPid: pid) - callsBefore : 0
        )
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
