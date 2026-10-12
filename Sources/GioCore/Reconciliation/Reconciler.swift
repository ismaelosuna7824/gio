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
    /// skipped because their frame was trusted, and the frame each window is
    /// known to sit at after the pass (read, verified by the write, trusted,
    /// or for a parked write its target or macOS's clamped landing). Failed
    /// and vanished windows have none.
    public var skippedReads: Int = 0
    public var settledFrames: [WindowID: CGRect] = [:]
    /// PF-A: windows left out of this pass because their app was still busy
    /// with a motion write after `finalPassMotionGrace`. Neither written nor
    /// failed: the caller runs another final pass once the app's lane is idle.
    public var deferred: [WindowID] = []
    /// PF-I diagnostics, not part of equality: why the focus call failed
    /// (`FrameFailureReporting.failureKind`, "other" for an untyped error),
    /// nil unless `focusFailed`.
    public var focusFailure: String?

    public static func == (lhs: ReconcileReport, rhs: ReconcileReport) -> Bool {
        lhs.applied == rhs.applied && lhs.alreadyCorrect == rhs.alreadyCorrect && lhs.parked == rhs.parked
            && lhs.vanished == rhs.vanished && lhs.failed == rhs.failed
            && lhs.failureNotes == rhs.failureNotes && lhs.failures == rhs.failures
            && lhs.focusChanged == rhs.focusChanged && lhs.focusFailed == rhs.focusFailed
            && lhs.deferred == rhs.deferred
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
    /// PF-I: refused focus lines, once per window per minute. Calling thread only.
    private var focusFailureGate = FocusFailureLogGate()
    /// SM-12: the newest dispatched lane per app (supersession) and the
    /// newest dispatched focus step (moved behind a newer write of its
    /// window). Calling thread only.
    private var openLanes: [pid_t: LaneState<ItemResult>] = [:]
    private var openFocus: DispatchFocusStep?
    private let focusBook = DispatchFocusBook()
    /// PF-K: `AXEnhancedUserInterface` off around each app's write batch.
    private let enhancedUI: EnhancedUIGuard
    /// PF-L: the WindowServer transport, its switch (the session sets it from
    /// `[behavior] skylight` and the runtime checks) and the windows it moved
    /// that Accessibility has not followed yet. Calling thread only.
    private let windowServer: WindowServerMover?
    public var windowServerEnabled = false
    private var ledger = WindowServerLedger()
    /// PF-M: does the WindowServer really move other apps' windows here?
    private var probe = WindowServerProbe()
    private let ownPID: pid_t

    /// Timing of the most recent `reconcile` pass (MO-01).
    public private(set) var lastTiming: ReflowTiming?

    /// Keep one reconciler alive across reflows: it remembers which apps are
    /// still stuck in an abandoned lane (MO-03). `enhancedUI` (PF-K) switches
    /// `AXEnhancedUserInterface` around write batches; `windowServer` (PF-L)
    /// moves parks, reveals and same-size pre-positions first. Neither ever
    /// touches `ownPID`.
    public init(
        actuator: Actuator, tolerance: CGFloat = 1,
        concurrency: LaneConcurrency = .concurrent(stallTimeout: 0.25),
        clock: @escaping ReflowClock = systemReflowClock,
        appName: @escaping @Sendable (pid_t) -> String? = { _ in nil },
        enhancedUI: EnhancedUserInterfaceSwitch? = nil,
        windowServer: WindowServerMover? = nil,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.actuator = actuator
        self.windowServer = windowServer
        self.ownPID = ownPID
        self.tolerance = tolerance
        self.concurrency = concurrency
        self.clock = clock
        self.names = AppNameCache(resolve: appName)
        let executor = LaneExecutor()
        let motion = MotionBook()
        let guardian = EnhancedUIGuard(control: enhancedUI, ownPID: ownPID, clock: clock)
        let worker = MotionWorker(actuator: actuator, clock: clock, enhancedUI: guardian)
        self.executor = executor
        self.motion = motion
        self.enhancedUI = guardian
        // PF-K: a motion lane switches its app off at the first frame and
        // leaves it off for the whole flight (a switch per frame would make
        // the app rebuild its accessibility state up to 120 times a second);
        // the app's final-pass lane, or the settle, switches it back on.
        motionLanes = MotionLanes(executor: executor, book: motion) { worker.write($0, into: motion) }
    }

    /// What happened to one window; folded into the report in serial order.
    fileprivate enum WindowOutcome: Sendable {
        case alreadyCorrect(CGRect)
        case vanished
        case failed(String, ReconcileFailure)
        case applied
        /// `landed`: where macOS clamped the parked position; nil at the target.
        case parkedApplied(landed: CGRect?)
    }

    fileprivate struct ItemResult: Sendable {
        let outcome: WindowOutcome
        let timing: WindowWriteTiming
        /// `clock()` when the write returned (a dispatched pass's span).
        let endedAt: TimeInterval
    }

    /// Everything a lane thread needs, detached from the reconciler.
    private struct LaneWorker: @unchecked Sendable {
        let actuator: Actuator
        let tolerance: CGFloat
        let clock: ReflowClock
        let enhancedUI: EnhancedUIGuard
        /// PF-L: windows the WindowServer moved: written even when the app
        /// already reports the target (it may not know where it is).
        let followUps: Set<WindowID>

        /// The timing carries no app name: names are resolved once per pid
        /// when the report is folded, never per write.
        func process(_ item: WriteItem) -> ItemResult {
            let tracks = actuator.tracksCalls
            let callsBefore = tracks ? actuator.axCallCount(forPid: item.id.pid) : 0
            let started = clock()
            let outcome = reconcileOne(item)
            let ended = clock()
            return ItemResult(
                outcome: outcome,
                timing: WindowWriteTiming(
                    id: item.id, app: "",
                    milliseconds: (ended - started) * 1000,
                    axCalls: tracks ? actuator.axCallCount(forPid: item.id.pid) - callsBefore : 0
                ),
                endedAt: ended
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
            let onTarget = matches(item.desired, actual)
            let followsWindowServer = followUps.contains(id)
            if !followsWindowServer, onTarget || item.parked.map({ isParked(actual, $0, tolerance) }) == true {
                return .alreadyCorrect(actual)
            }
            // PF-L: after a WindowServer move the app may report its target
            // and still not know it: write the position anyway.
            let current = onTarget ? forcingPosition(item.desired) : actual
            do {
                enhancedUI.willWrite(pid: id.pid)
                try actuator.setFrame(item.desired, from: current, for: id, verify: item.parked == nil)
                return item.parked == nil ? .applied : .parkedApplied(landed: nil)
            } catch {
                // macOS may clamp a parked position; accept a landing that is
                // still parked (size kept, small strip on the intended side).
                if let parked = item.parked, let landed = try? actuator.frame(of: id),
                   isParked(landed, parked, tolerance)
                {
                    return .parkedApplied(landed: landed)
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
    /// PF-L: `windowServerFirst` (`planWindowServerFirst`) are moved by the
    /// WindowServer in one transaction before any lane starts; their
    /// Accessibility write follows in the lanes as usual. TG-05: once those
    /// writes returned, every window whose WindowServer position Gio moved
    /// (this pass or an earlier flight) and whose app took the frame gets one
    /// more transaction to exactly that frame, so the WindowServer draws what
    /// the app reports (`alignWindowServer`).
    @discardableResult
    public func reconcile(
        frames: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget] = [:],
        focused: WindowID?,
        currentlyFocused: WindowID?,
        trusted: TrustedFrames = TrustedFrames(),
        windowServerFirst: Set<WindowID> = []
    ) -> ReconcileReport {
        var report = ReconcileReport()
        // An animation frame still being written would make its app look
        // busy and fail; let it land first, but only for the apps this pass
        // writes and only for a short grace (PF-A): a slow app is deferred
        // instead of holding the session queue for every other window.
        let pids = Set(frames.keys.map(\.pid)).union(parked.keys.map(\.pid))
        let stuck = motionLanes.waitForIdle(pids: pids, timeout: finalPassMotionGrace)
        let started = clock()
        var toWrite = frames
        var toPark = parked
        if !stuck.isEmpty {
            toWrite = toWrite.filter { !stuck.contains($0.key.pid) }
            toPark = toPark.filter { !stuck.contains($0.key.pid) }
            report.deferred = Set(frames.keys).union(parked.keys).filter { stuck.contains($0.pid) }.sorted()
        }
        moveFirst(windowServerFirst, frames: toWrite, parked: toPark)
        (toWrite, toPark) = skipTrusted(frames: toWrite, parked: toPark, trusted: trusted, into: &report)
        let lanes = planWriteLanes(frames: toWrite, parked: toPark)
        let followUps = ledger.snapshot(Set(toWrite.keys).union(toPark.keys))
        let worker = LaneWorker(
            actuator: actuator, tolerance: tolerance, clock: clock, enhancedUI: enhancedUI,
            followUps: Set(followUps.keys)
        )
        let results = executor.run(lanes: lanes, mode: concurrency, epilogue: batchEnded) { worker.process($0) }
        let windowTimings = fold(lanes: lanes, results: results, frames: frames, parked: parked, into: &report)
        let followed = ledger.followed(report, snapshot: followUps)
        let aligned = alignWindowServer(to: report.settledFrames.filter { followed.contains($0.key) })
        if !aligned.isEmpty {
            GioLog.record(.debug, "skylight aligned windows=\(aligned.count)")
        }
        probeForget(Set(toWrite.keys).union(toPark.keys).union(windowServerFirst))
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
                report.focusFailure = focusFailureKind(error)
                logFocusFailure(focused, reason: focusFailureKind(error))
            }
            focusMilliseconds = (clock() - focusStart) * 1000
            focusCalls = tracks ? actuator.axCallCount(forPid: focused.pid) - callsBefore : 0
        }
        finish(
            report, timing: ReflowTiming(
                totalMilliseconds: (clock() - started) * 1000, focusMilliseconds: focusMilliseconds,
                windows: windowTimings, focusAXCalls: focusCalls
            )
        )
        return report
    }

    /// SM-12: a final pass under a snapshot overlay. The same writes as
    /// `reconcile`, started on the per-app lanes without waiting for them:
    /// the overlay hides the real windows, so a slow app must not hold the
    /// caller (the session queue). `collect` folds the outcome at the
    /// flight's settle. Differences from `reconcile`:
    /// - no motion grace: the app's queued motion frames are discarded and
    ///   its lane waits (on its own thread, up to twice the stall timeout)
    ///   for the in-flight motion write instead of deferring the window;
    /// - a newer dispatch supersedes this one's not-yet-started writes of
    ///   the windows it writes again (latest wins, nothing is failed);
    /// - the focus intent runs on the focused window's app lane after that
    ///   lane's writes, only while it is the newest intent (an older one
    ///   never lands after a newer one), and moves behind a newer pass that
    ///   writes its window again without an intent of its own.
    /// PF-L: `windowServerFirst` move through the WindowServer before the
    /// lanes start, as in `reconcile`.
    public func dispatch(
        frames: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget] = [:],
        focused: WindowID?,
        currentlyFocused: WindowID?,
        trusted: TrustedFrames = TrustedFrames(),
        windowServerFirst: Set<WindowID> = []
    ) -> DispatchedPass {
        let started = clock()
        var report = ReconcileReport()
        let pids = Set(frames.keys.map(\.pid)).union(parked.keys.map(\.pid))
        motionLanes.discardPending(pids: pids)
        moveFirst(windowServerFirst, frames: frames, parked: parked)
        let (toWrite, toPark) = skipTrusted(frames: frames, parked: parked, trusted: trusted, into: &report)
        var lanes = planWriteLanes(frames: toWrite, parked: toPark)
        let written = Set(toWrite.keys).union(toPark.keys)
        let followUps = ledger.snapshot(written)
        probeForget(written.union(windowServerFirst))
        var step: DispatchFocusStep?
        if let focused, focused != currentlyFocused, parked[focused] == nil {
            step = DispatchFocusStep(target: focused, generation: focusBook.issue())
        } else if focused == nil, let pending = openFocus, written.contains(pending.target),
                  parked[pending.target] == nil, pending.handOver()
        {
            step = DispatchFocusStep(target: pending.target, generation: pending.generation)
        }
        if let step {
            openFocus = step
            if !lanes.contains(where: { $0.pid == step.target.pid }) {
                lanes.append(WriteLane(pid: step.target.pid, items: []))
            }
        }
        var tails: [pid_t: @Sendable () -> Void] = [:]
        if let step {
            let actuator = UncheckedSendableBox(actuator)
            let book = focusBook
            let clock = clock
            tails[step.target.pid] = {
                step.run(book: book, clock: clock) { try actuator.value.focus(id: $0) }
            }
        }
        let worker = LaneWorker(
            actuator: actuator, tolerance: tolerance, clock: clock, enhancedUI: enhancedUI,
            followUps: Set(followUps.keys)
        )
        let epilogue = batchEnded
        let launched: LaunchedLanes<ItemResult>
        switch concurrency {
        case .serial:
            launched = executor.launch(
                lanes: lanes, claimWait: nil, serial: true, tails: tails, epilogue: epilogue
            ) { worker.process($0) }
        case .concurrent(let stall):
            for lane in lanes where !lane.items.isEmpty {
                openLanes[lane.pid]?.supersede(Set(lane.items.map(\.id)))
            }
            launched = executor.launch(
                lanes: lanes, claimWait: stall * 2, tails: tails, epilogue: epilogue
            ) { worker.process($0) }
            for (lane, state) in zip(lanes, launched.states) where !lane.items.isEmpty {
                openLanes[lane.pid] = state
            }
        }
        GioLog.record(
            .debug,
            "reconcile dispatched windows=\(written.count) lanes=\(lanes.count) skippedReads=\(report.skippedReads) "
                + "ms=\(String(format: "%.1f", (clock() - started) * 1000))"
        )
        var landingBounds: [WindowID: TimeInterval] = [:]
        for lane in lanes {
            for (position, item) in lane.items.enumerated() {
                if case .concurrent(let stall) = concurrency {
                    landingBounds[item.id] = stall * 2 + stall * Double(position + 1)
                } else {
                    landingBounds[item.id] = 0
                }
            }
        }
        return DispatchedPass(
            launched: launched, frames: frames, parked: parked, report: report, focus: step, started: started,
            landingBounds: landingBounds, followUps: followUps
        )
    }

    /// SM-12: wait for a dispatched pass (bounded like `reconcile`: a lane
    /// with no progress for the stall timeout is abandoned and its windows
    /// fail with "timeout"; waiting for the app claim is not a stall) and
    /// fold its report. A focus step its lane never reached runs here. Same logs as `reconcile`;
    /// the timing spans dispatch to the last lane's end. Superseded writes
    /// appear nowhere in the report: the newer pass reports them. TG-05: no
    /// WindowServer alignment here, unlike `reconcile`: by the time a pass is
    /// collected a newer one may already have written the window elsewhere
    /// on its lane, so the render check's SkyLight repair covers this path.
    public func collect(_ pass: DispatchedPass) -> ReconcileReport {
        let stall: TimeInterval
        if case .concurrent(let timeout) = concurrency {
            stall = timeout
        } else {
            stall = 0
        }
        let results = pass.launched.await(stallTimeout: stall)
        if let focus = pass.focus, focus.outcome.result == .notRun {
            // SM-13: the lane never reached its focus step (app busy past the
            // claim wait, lane abandoned): focus now, as `reconcile` always
            // did. `taken` stops a second run; an older intent stays stale.
            focus.run(book: focusBook, clock: clock) { try actuator.focus(id: $0) }
        }
        for (lane, state) in zip(pass.launched.lanes, pass.launched.states) where openLanes[lane.pid] === state {
            openLanes.removeValue(forKey: lane.pid)
        }
        if let focus = pass.focus, openFocus === focus {
            openFocus = nil
        }
        var report = pass.report
        let windowTimings = fold(
            lanes: pass.launched.lanes, results: results, frames: pass.frames, parked: pass.parked, into: &report
        )
        ledger.followed(report, snapshot: pass.followUps)
        var ended = pass.started
        var timedOut = false
        for result in results.values {
            switch result {
            case .completed(let item):
                ended = max(ended, item.endedAt)
            case .timedOut, .skippedBusy:
                timedOut = true
            case .superseded:
                break
            }
        }
        var focusMilliseconds = 0.0
        if let focus = pass.focus {
            let outcome = focus.outcome
            switch outcome.result {
            case .changed:
                report.focusChanged = true
            case .failed, .notRun:
                let reason = outcome.failure ?? "notRun"
                report.focusFailed = true
                report.focusFailure = reason
                logFocusFailure(focus.target, reason: reason)
            case .stale, .handedOver:
                break
            }
            focusMilliseconds = outcome.milliseconds
            if let end = outcome.endedAt {
                ended = max(ended, end)
            }
        }
        if timedOut {
            ended = max(ended, clock())
        }
        finish(
            report, timing: ReflowTiming(
                totalMilliseconds: (ended - pass.started) * 1000, focusMilliseconds: focusMilliseconds,
                windows: windowTimings, focusAXCalls: 0
            )
        )
        return report
    }

    /// SM-12: lanes started by `dispatch`, folded by `collect`.
    public final class DispatchedPass: @unchecked Sendable {
        fileprivate let launched: LaunchedLanes<ItemResult>
        fileprivate let frames: [WindowID: CGRect]
        fileprivate let parked: [WindowID: ParkedTarget]
        fileprivate let report: ReconcileReport
        fileprivate let focus: DispatchFocusStep?
        fileprivate let started: TimeInterval
        /// PF-L: the WindowServer moves this pass's writes follow.
        fileprivate let followUps: [WindowID: Int]
        /// SM-13: per written window, the latest a write can land after
        /// dispatch (claim wait plus one stall per write of its lane up to
        /// and including its own; 0 when written before `dispatch` returned).
        /// The session's echo gate covers that span.
        public let landingBounds: [WindowID: TimeInterval]

        fileprivate init(
            launched: LaunchedLanes<ItemResult>, frames: [WindowID: CGRect], parked: [WindowID: ParkedTarget],
            report: ReconcileReport, focus: DispatchFocusStep?, started: TimeInterval,
            landingBounds: [WindowID: TimeInterval], followUps: [WindowID: Int]
        ) {
            self.launched = launched
            self.frames = frames
            self.parked = parked
            self.report = report
            self.focus = focus
            self.started = started
            self.landingBounds = landingBounds
            self.followUps = followUps
        }

        /// Every lane returned: `collect` will not wait.
        public var isFinished: Bool {
            launched.isFinished
        }
    }

    /// PA-04: a window sitting at a frame Gio placed and verified needs
    /// neither the two AX reads nor a write. Windows that moved in this
    /// motion are not trusted by the caller, so they are still verified.
    /// PF-L: a window the WindowServer moved is never skipped: its app has
    /// not been told yet.
    private func skipTrusted(
        frames: [WindowID: CGRect], parked: [WindowID: ParkedTarget], trusted: TrustedFrames,
        into report: inout ReconcileReport
    ) -> ([WindowID: CGRect], [WindowID: ParkedTarget]) {
        var toWrite = frames
        var toPark = parked
        guard trusted.count > 0 else {
            return (toWrite, toPark)
        }
        var skipped: [WindowID] = []
        for (id, target) in toPark where !ledger.contains(id) && trusted.canSkipRead(id, desired: target.frame) {
            skipped.append(id)
            toPark.removeValue(forKey: id)
            report.settledFrames[id] = target.frame
        }
        for (id, frame) in toWrite
            where parked[id] == nil && !ledger.contains(id) && trusted.canSkipRead(id, desired: frame)
        {
            skipped.append(id)
            toWrite.removeValue(forKey: id)
            report.settledFrames[id] = frame
        }
        skipped.sort()
        report.alreadyCorrect.append(contentsOf: skipped)
        report.skippedReads = skipped.count
        return (toWrite, toPark)
    }

    /// Fold lane results into `report` in serial order; returns the timings.
    private func fold(
        lanes: [WriteLane], results: [Int: LaneItemResult<ItemResult>], frames: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget], into report: inout ReconcileReport
    ) -> [WindowWriteTiming] {
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
                case .parkedApplied(let landed):
                    if landed != nil {
                        GioLog.record(.debug, "parked clamped id=\(id.pid):\(id.elementID)")
                    }
                    report.parked.append(id)
                    // Where the app has it: the target, or macOS's clamp.
                    report.settledFrames[id] = landed ?? item.desired
                }
            case .superseded:
                break
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
        return windowTimings
    }

    /// The pass's timing and log lines (shared by `reconcile` and `collect`).
    private func finish(_ report: ReconcileReport, timing: ReflowTiming) {
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
            logFocusFailure(id, reason: focusFailureKind(error))
            return .failed
        }
    }

    /// PF-I: a refused focus repeats once per key press onto the window;
    /// log it once per window per minute, with the reason and the count held
    /// back since the previous line.
    private func logFocusFailure(_ id: WindowID, reason: String) {
        guard let suppressed = focusFailureGate.admit(id, now: clock()) else {
            return
        }
        GioLog.record(
            .debug,
            "focus failed id=\(id.pid):\(id.elementID) app=\(names.display(id.pid)) reason=\(reason) suppressed=\(suppressed)"
        )
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

    /// PF-M: the runtime probe's verdict so far. PF-P: a failed probe turns
    /// into a new trial (`retrying`) once its retry is due.
    public var windowServerProbe: WindowServerProbeState {
        probe.refresh(at: clock())
        return probe.state
    }

    /// PF-M: one tick of hide and reveal flights (PF-O: every same-size
    /// flight of the live renderer), all in one WindowServer transaction, no
    /// Accessibility write (the final pass follows through the ledger).
    /// Never blocks. While a probe trial runs, it first looks where the
    /// WindowServer draws up to two windows moved on earlier ticks of the
    /// flight and logs the verdict with its evidence; while the probe is
    /// failed, nothing is moved (here or in instant passes) and the player
    /// writes these frames through Accessibility. Returns the windows moved.
    public func submitWindowServerMotion(_ writes: [MotionWrite]) -> Set<WindowID> {
        guard !writes.isEmpty, windowServerUsable, let windowServer else {
            return []
        }
        let now = clock()
        let targets = probe.observationTargets()
        if !targets.isEmpty, let verdict = probe.observe(windowServer.frames(of: targets), at: now) {
            GioLog.record(.info, verdict.logLine)
            if verdict.result == .failed {
                return []
            }
        }
        var frames: [WindowID: CGRect] = [:]
        for write in writes {
            frames[write.id] = write.to
        }
        let moved = moveThroughWindowServer(frames)
        if probe.isTrialRunning {
            for write in writes where moved.contains(write.id) {
                if let windowID = windowServer.windowServerID(of: write.id) {
                    probe.moved(windowID: windowID, from: write.from, to: write.to, at: now)
                }
            }
        }
        return moved
    }

    /// PF-L/PF-M: switched on by the session, present, not refuted by the
    /// probe (PF-P: or refuted, but its retry is due).
    private var windowServerUsable: Bool {
        guard windowServerEnabled, windowServer != nil else {
            return false
        }
        probe.refresh(at: clock())
        return probe.state != .failed
    }

    /// PF-P: these windows are moved outside a flight's ticks (an
    /// Accessibility write, an alignment, a park or pre-position): what the
    /// probe saw of them proves nothing about the flight's commits any more.
    private func probeForget(_ ids: some Sequence<WindowID>) {
        guard probe.isTrialRunning, let windowServer else {
            return
        }
        probe.forget(ids.compactMap { windowServer.windowServerID(of: $0) })
    }

    /// NC-07 / HD-02: put hidden incoming windows just below their target
    /// before a workspace-switch animation. Same lanes and lean write as
    /// motion frames (known origin, unverified), no reads, never focus.
    /// Windows without a known origin in `from` are skipped. Returns the ids
    /// actually written, sorted, so the caller can record them for echo
    /// suppression and update its physical-frame memory.
    /// PF-02: `waitForMotion: false` when the caller already waited, or
    /// writes only entries (new windows no motion lane holds a frame for).
    /// PF-L: a pre-position that keeps the size is a pure move: the
    /// WindowServer makes it, in one transaction, without the app; the
    /// motion's or the final pass's Accessibility writes follow it. One that
    /// resizes (or with no WindowServer) is written through Accessibility.
    @discardableResult
    public func preposition(
        frames: [WindowID: CGRect], from: [WindowID: CGRect], waitForMotion: Bool = true
    ) -> [WindowID] {
        let known = frames.filter { from[$0.key] != nil }
        guard !known.isEmpty else {
            return []
        }
        probeForget(known.keys)
        if waitForMotion {
            // A queued motion frame landing after the move would undo it.
            waitForMotionIdle(timeout: 0.3)
        }
        let moved = moveThroughWindowServer(known.filter { sameSize($0.value, from[$0.key]!) })
        let rest = known.filter { !moved.contains($0.key) }
        guard !rest.isEmpty else {
            return moved.sorted()
        }
        let lanes = planWriteLanes(frames: rest, parked: [:])
        let actuator = actuator
        let writer = PrepositionWriter(actuator: actuator, enhancedUI: enhancedUI)
        let results = executor.run(lanes: lanes, mode: concurrency, epilogue: batchEnded) { item in
            writer.write(item.desired, from: from[item.id]!, for: item.id)
        }
        var written = Array(moved)
        for item in lanes.flatMap(\.items).sorted(by: { $0.index < $1.index }) {
            if case .completed(true)? = results[item.index] {
                written.append(item.id)
            }
        }
        return written.sorted()
    }

    /// PF-L: windows the WindowServer moved that no Accessibility write has
    /// followed yet, with where the WindowServer put them.
    public var windowServerPending: [WindowID: CGRect] {
        ledger.frames
    }

    /// PF-L: tell every pending window's app where the WindowServer put it
    /// (one lean Accessibility write each, waiting, bounded by the stall
    /// timeout). Quit and restore-all run it first: the restore reads the
    /// apps' frames, and an app that never learned its window was hidden
    /// would report it on screen.
    public func syncWindowServerMoves() {
        let pending = ledger.frames
        guard !pending.isEmpty else {
            return
        }
        probeForget(pending.keys)
        let snapshot = ledger.snapshot(pending.keys)
        let lanes = planWriteLanes(frames: pending, parked: [:])
        let writer = PrepositionWriter(actuator: actuator, enhancedUI: enhancedUI)
        let results = executor.run(lanes: lanes, mode: concurrency, epilogue: batchEnded) { item in
            writer.write(item.desired, from: forcingPosition(item.desired), for: item.id)
        }
        var written: [WindowID] = []
        for item in lanes.flatMap(\.items) {
            if case .completed(true)? = results[item.index] {
                written.append(item.id)
            }
        }
        ledger.followed(written, snapshot: snapshot)
    }

    /// PF-L: the parks and reveals of a pass, before its lanes start.
    private func moveFirst(_ ids: Set<WindowID>, frames: [WindowID: CGRect], parked: [WindowID: ParkedTarget]) {
        guard !ids.isEmpty else {
            return
        }
        var targets: [WindowID: CGRect] = [:]
        for id in ids {
            if let target = parked[id] {
                targets[id] = target.frame
            } else if let frame = frames[id] {
                targets[id] = frame
            }
        }
        _ = moveThroughWindowServer(targets)
    }

    /// PF-L: one WindowServer transaction for every window with a known
    /// `CGWindowID` (never Gio's own). Returns the windows it moved, now
    /// pending until an Accessibility write follows; none when the transport
    /// is off, missing or refused the transaction.
    private func moveThroughWindowServer(_ targets: [WindowID: CGRect]) -> Set<WindowID> {
        let moved = commitThroughWindowServer(targets)
        for id in moved.sorted() {
            ledger.record(id, frame: targets[id]!)
        }
        return moved
    }

    /// TG-05: move each window's WindowServer copy to the frame its app
    /// already holds (`frames`: what the app took or reports), in one
    /// transaction. Nothing becomes pending: the app knows these frames, so
    /// no Accessibility write needs to follow. The final pass aligns every
    /// window it followed up (`reconcile`), and the render check repairs a
    /// window the WindowServer draws away from its app's frame (live, after a
    /// swipe, Accessibility writes and nudges did not move such windows).
    /// Returns the windows moved; none when the transport is off, missing,
    /// refuted by the probe or refused the transaction. Never Gio's own.
    @discardableResult
    public func alignWindowServer(to frames: [WindowID: CGRect]) -> Set<WindowID> {
        probeForget(frames.keys)
        return commitThroughWindowServer(frames)
    }

    private func commitThroughWindowServer(_ targets: [WindowID: CGRect]) -> Set<WindowID> {
        guard windowServerUsable, let windowServer, !targets.isEmpty else {
            return []
        }
        var moves: [WindowServerMove] = []
        var ids: [WindowID] = []
        for id in targets.keys.sorted() where id.pid != ownPID {
            guard let windowID = windowServer.windowServerID(of: id) else {
                continue
            }
            moves.append(WindowServerMove(windowID: windowID, frame: targets[id]!))
            ids.append(id)
        }
        guard !moves.isEmpty, windowServer.commit(moves) else {
            return []
        }
        return Set(ids)
    }

    private func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
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
        probeForget(known.keys)
        waitForMotionIdle(timeout: 0.3)
        let lanes = planWriteLanes(frames: known.mapValues { $0.last! }, parked: [:])
        let writer = NudgeWriter(actuator: actuator, enhancedUI: enhancedUI)
        let results = executor.run(lanes: lanes, mode: concurrency, epilogue: batchEnded) { item in
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
    /// mid-zoom and never writes it until the zoom settled. A lane abandoned
    /// for stalling (the action blocks while the app runs its own animation)
    /// is `pending`, not a failure: the press may still land.
    public func pressZoom(_ id: WindowID) -> ZoomPressResult {
        runZoomOperation(on: id, timedOut: .pending(code: nil)) { $0.pressZoom(id: id) }
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

    /// PF-02: a motion write is queued or running on some app's lane.
    public var hasMotionWritesInFlight: Bool {
        motionLanes.isBusy
    }

    /// PF-A: one of `pids` still has a motion write queued or running.
    public func isMotionBusy(pids: Set<pid_t>) -> Bool {
        motionLanes.isBusy(pids: pids)
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
        enhancedUI.forget(pid: pid)
        ledger.forget(pid: pid)
    }

    /// PF-K: apps Gio left with `AXEnhancedUserInterface` off: a motion
    /// whose final pass has not visited them yet, or a restore the app did
    /// not take (typically a hung app).
    public var pendingEnhancedUIRestores: Set<pid_t> {
        enhancedUI.pendingRestores
    }

    /// PF-K: switch the pending apps back on, each on its own lane. An app
    /// whose lane is busy is skipped and stays pending (that lane's batch, or
    /// the next settle, restores it). The session does not wait (after a
    /// settle): a hung app must not hold it; shutdown waits, bounded by the
    /// stall timeout.
    public func restoreEnhancedUI(waiting: Bool = false) {
        let pending = enhancedUI.pendingRestores
        guard !pending.isEmpty else {
            return
        }
        let lanes = pending.sorted().map {
            WriteLane(pid: $0, items: [WriteItem(index: 0, id: WindowID(pid: $0, elementID: 0), desired: .zero, parked: nil)])
        }
        let guardian = enhancedUI
        let work: @Sendable (WriteItem) -> Void = { guardian.restore(pid: $0.id.pid) }
        if waiting {
            _ = executor.run(lanes: lanes, mode: concurrency, work: work)
        } else {
            let serial = concurrency == .serial
            _ = executor.launch(lanes: lanes, claimWait: nil, serial: serial, work: work)
        }
    }

    /// PF-K: the lane epilogue that ends an app's write batch.
    private var batchEnded: @Sendable (pid_t) -> Void {
        let guardian = enhancedUI
        return { guardian.batchEnded(pid: $0) }
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
    let enhancedUI: EnhancedUIGuard

    func write(_ steps: [CGRect], for id: WindowID) -> Bool {
        guard var current = (try? actuator.frame(of: id)) ?? nil else {
            return false
        }
        enhancedUI.willWrite(pid: id.pid)
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
    let enhancedUI: EnhancedUIGuard

    func write(_ frame: CGRect, from current: CGRect, for id: WindowID) -> Bool {
        enhancedUI.willWrite(pid: id.pid)
        return (try? actuator.setFrame(frame, from: current, for: id, verify: false)) != nil
    }
}

private struct MotionWorker<Actuator: WindowActuator>: @unchecked Sendable {
    let actuator: Actuator
    let clock: ReflowClock
    let enhancedUI: EnhancedUIGuard

    func write(_ write: MotionWrite, into book: MotionBook) {
        let pid = write.id.pid
        // PF-K: switched once per batch, outside the frame write's timing.
        enhancedUI.willWrite(pid: pid)
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

/// PF-A: how long the final pass lets an in-flight motion write of an app it
/// is about to write land (a normal write takes a few ms; live, Music hung
/// for 251 ms). Past it, that app's windows are deferred, not waited for.
public let finalPassMotionGrace: TimeInterval = 0.1

/// PF-I: the stable reason of a failed focus call for reports and logs.
func focusFailureKind(_ error: Error) -> String {
    (error as? FrameFailureReporting)?.failureKind ?? "other"
}

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

/// SM-12: keyboard intents of dispatched passes. Only the newest intent may
/// focus. Issuing never waits (the session queue issues); the newest check
/// and the focus call share `running`, so an older intent whose check passed
/// finishes before a newer one starts and can never land after it.
final class DispatchFocusBook: @unchecked Sendable {
    private let lock = NSLock()
    private let running = NSLock()
    private var latest = 0

    func issue() -> Int {
        lock.withLock {
            latest += 1
            return latest
        }
    }

    /// Runs `body` when `generation` is still the newest intent.
    func runIfLatest(_ generation: Int, _ body: () -> Void) -> Bool {
        running.lock()
        defer { running.unlock() }
        guard lock.withLock({ latest == generation }) else {
            return false
        }
        body()
        return true
    }
}

/// SM-12: the focus step of one dispatched pass, run on the focused
/// window's app lane after its writes, or handed over to a newer pass that
/// writes the window again.
final class DispatchFocusStep: @unchecked Sendable {
    enum Result: Sendable {
        /// The lane never reached it (app busy, lane abandoned) and neither
        /// did `collect` yet.
        case notRun
        case changed
        case failed
        /// A newer intent was issued first.
        case stale
        /// A newer pass writes the window again and focuses it after that.
        case handedOver
    }

    struct Outcome: Sendable {
        var result: Result = .notRun
        var milliseconds: Double = 0
        var endedAt: TimeInterval?
        /// PF-I: `focusFailureKind` of a `.failed` focus call.
        var failure: String?
    }

    let target: WindowID
    let generation: Int
    private let lock = NSLock()
    private var taken = false
    private var recorded = Outcome()

    init(target: WindowID, generation: Int) {
        self.target = target
        self.generation = generation
    }

    var outcome: Outcome {
        lock.withLock { recorded }
    }

    /// The newer pass takes the step over; false once the lane started it.
    func handOver() -> Bool {
        lock.withLock {
            guard !taken else { return false }
            taken = true
            recorded.result = .handedOver
            return true
        }
    }

    func run(book: DispatchFocusBook, clock: ReflowClock, focus: (WindowID) throws -> Void) {
        guard lock.withLock({ () -> Bool in
            guard !taken else { return false }
            taken = true
            return true
        }) else {
            return
        }
        let started = clock()
        var result = Result.stale
        var failure: String?
        _ = book.runIfLatest(generation) {
            do {
                try focus(target)
                result = .changed
            } catch {
                result = .failed
                failure = focusFailureKind(error)
            }
        }
        let ended = clock()
        lock.withLock {
            recorded = Outcome(
                result: result, milliseconds: (ended - started) * 1000, endedAt: ended, failure: failure
            )
        }
    }
}
