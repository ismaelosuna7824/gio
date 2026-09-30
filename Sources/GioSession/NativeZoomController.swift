import CoreGraphics
import Foundation
import GioCore

/// Native zoom: a maximize that grows a single-window column presses the
/// app's own zoom instead of writing a size. Windows mid-zoom (not written
/// by Gio), waiting for a verdict, or sitting at an accepted frame; the
/// maximize toggle's pending request; the settle pollers (one short-lived
/// strict timer per window) and the post-correction verifications with their
/// WindowServer ids. Session queue only. Logs carry app names, never titles.
public final class NativeZoomController: @unchecked Sendable {
    public struct Context {
        public var isShuttingDown: () -> Bool
        public var isMotionActive: () -> Bool
        public var isFlightActive: () -> Bool
        /// `[animations] native-zoom` is on.
        public var isEnabled: () -> Bool
        /// The snapshot renderer carries motions (it would fly an image of the
        /// window over its own zoom).
        public var snapshotRendererUsable: () -> Bool
        public var physicalFrame: (WindowID) -> CGRect?
        /// Sets (or, with nil, forgets) the window's physical frame.
        public var setPhysicalFrame: (WindowID, CGRect?) -> Void
        public var invalidateTrust: (WindowID) -> Void
        public var trust: (WindowID, CGRect) -> Void
        /// A frame the window reached through Gio or its zoom: echoes are dropped.
        public var recordEcho: (WindowID, CGRect, TimeInterval) -> Void
        /// The WindowServer window of `id` near `frame` (one query), if unambiguous.
        public var windowServerID: (WindowID, CGRect) -> UInt32?
        /// The WindowServer bounds of that window (Cocoa coordinates).
        public var windowServerBounds: (UInt32) -> CGRect?
        public var zoomAvailability: (WindowID) -> ZoomAvailability
        public var pressZoom: (WindowID) -> ZoomPressResult
        /// One corrective write of `target` (trust already invalidated by the
        /// host); true when it failed, nil without a reconciler.
        public var reassert: (WindowID, CGRect) -> Bool?
        /// The last verification ended: the dim may come back.
        public var updateDim: () -> Void
        /// One instant pass judges zooms that ended at rest.
        public var instantReflow: () -> Void
        public var appName: (pid_t) -> String
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            isShuttingDown: @escaping () -> Bool, isMotionActive: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isEnabled: @escaping () -> Bool,
            snapshotRendererUsable: @escaping () -> Bool, physicalFrame: @escaping (WindowID) -> CGRect?,
            setPhysicalFrame: @escaping (WindowID, CGRect?) -> Void, invalidateTrust: @escaping (WindowID) -> Void,
            trust: @escaping (WindowID, CGRect) -> Void, recordEcho: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            windowServerID: @escaping (WindowID, CGRect) -> UInt32?,
            windowServerBounds: @escaping (UInt32) -> CGRect?,
            zoomAvailability: @escaping (WindowID) -> ZoomAvailability,
            pressZoom: @escaping (WindowID) -> ZoomPressResult, reassert: @escaping (WindowID, CGRect) -> Bool?,
            updateDim: @escaping () -> Void, instantReflow: @escaping () -> Void,
            appName: @escaping (pid_t) -> String, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.isShuttingDown = isShuttingDown
            self.isMotionActive = isMotionActive
            self.isFlightActive = isFlightActive
            self.isEnabled = isEnabled
            self.snapshotRendererUsable = snapshotRendererUsable
            self.physicalFrame = physicalFrame
            self.setPhysicalFrame = setPhysicalFrame
            self.invalidateTrust = invalidateTrust
            self.trust = trust
            self.recordEcho = recordEcho
            self.windowServerID = windowServerID
            self.windowServerBounds = windowServerBounds
            self.zoomAvailability = zoomAvailability
            self.pressZoom = pressZoom
            self.reassert = reassert
            self.updateDim = updateDim
            self.instantReflow = instantReflow
            self.appName = appName
            self.log = log
            self.now = now
        }
    }

    /// A zoom this pass decided to press.
    public struct Job: Sendable {
        public let id: WindowID
        public let action: NativeZoomAction
        public let windowID: UInt32
        public let start: CGRect
    }

    /// A zoom that ended with a write: its verdict is logged once the window
    /// has been checked again (`verified=`), with at most one reassert.
    private struct Verification {
        let action: NativeZoomAction
        let outcome: NativeZoomOutcome
        let settle: NativeZoomSettle
        let target: CGRect
        var verifier: NativeZoomVerifier
        var writeFailed: Bool
        var scheduled = false
        var generation = 0
    }

    /// The settle poller's tracker, mutated by the timer handler only.
    private final class TrackerBox: @unchecked Sendable {
        var tracker: NativeZoomSettleTracker

        init(_ tracker: NativeZoomSettleTracker) {
            self.tracker = tracker
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var book = NativeZoomBook()
    private var pendingRequest: NativeZoomRequest?
    private var timers: [WindowID: SessionTimer] = [:]
    private var verifications: [WindowID: Verification] = [:]
    private var windowServerIDs: [WindowID: UInt32] = [:]

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    // MARK: Queries

    /// In flight, awaiting its verdict or being verified.
    public func isBusy(_ id: WindowID) -> Bool {
        book.isBusy(id)
    }

    /// A zoom is animating, awaiting its verdict or being verified (the dim holds).
    public var isActive: Bool {
        book.hasInFlight || book.hasResolved || !verifications.isEmpty
    }

    public var hasInFlight: Bool {
        book.hasInFlight
    }

    public func isInFlight(_ id: WindowID) -> Bool {
        book.isInFlight(id)
    }

    /// Frames minus the windows mid-zoom: nothing of Gio writes them.
    public func withoutInFlight(_ frames: [WindowID: CGRect]) -> [WindowID: CGRect] {
        book.withoutInFlight(frames)
    }

    // MARK: Session events

    /// The maximize toggle on the focused column: the next pass decides.
    public func requestToggle(in workspace: Workspace) {
        pendingRequest = nativeZoomRequest(in: workspace) { [book] in book.isNativeMaximized($0) }
    }

    /// The window moved on its own: it no longer sits at an accepted frame.
    public func forget(_ id: WindowID) {
        book.forget(id)
    }

    /// The window is gone: its poller and verification end too.
    public func purge(_ id: WindowID) {
        book.forget(id)
        timers.removeValue(forKey: id)?.cancel()
        dropVerification(id)
    }

    // MARK: Reflow integration

    /// Windows whose zoom ended since the last pass, to judge against this
    /// pass's layout target.
    public func takeResolved() -> [NativeZoomResolution] {
        book.takeResolved()
    }

    /// Substitute accepted zoom frames for unchanged layout targets.
    public func applyAccepted(to frames: [WindowID: CGRect], parked: Set<WindowID>) -> [WindowID: CGRect] {
        book.applyAccepted(to: frames, parked: parked)
    }

    /// Judge the zooms that ended against the layout target of `plan`. An
    /// accepted zoom keeps the app's own frame (physical, trusted and echo
    /// gate updated, no correcting write); the others leave the window at the
    /// frame it reached so this pass's ordinary write brings it to the target,
    /// and are verified again shortly after (`scheduleVerifications`).
    public func judge(_ pending: inout [NativeZoomResolution], plan: ParkingPlan, viewport: CGRect) {
        var rest: [NativeZoomResolution] = []
        let now = context.now()
        for resolution in pending {
            let id = resolution.id
            guard let target = plan.visible[id], plan.parked[id] == nil else {
                rest.append(resolution)
                continue
            }
            let outcome = nativeZoomOutcome(settle: resolution.settle, target: target, visible: viewport)
            let settleMs = resolution.settle.settleMilliseconds
            context.invalidateTrust(id)
            var actualFrame: CGRect?
            if case .settled(let actual, _, _) = resolution.settle {
                actualFrame = actual
                context.setPhysicalFrame(id, actual)
                // Late frame events of the zoom are echoes of where it landed.
                context.recordEcho(id, actual, now)
            } else {
                // Unknown frame: the pass reads it from the window itself.
                context.setPhysicalFrame(id, nil)
            }
            if outcome == .exact, let actualFrame {
                log(
                    id, action: resolution.action, outcome: outcome, milliseconds: resolution.settle.milliseconds,
                    errorCode: resolution.settle.errorCode, settleMilliseconds: settleMs, verified: true
                )
                book.accept(id, target: target, actual: actualFrame)
                context.trust(id, actualFrame)
                windowServerIDs.removeValue(forKey: id)
            } else if outcome == .fallback(.pressFailed) {
                log(
                    id, action: resolution.action, outcome: outcome, milliseconds: resolution.settle.milliseconds,
                    errorCode: resolution.settle.errorCode, settleMilliseconds: settleMs
                )
                windowServerIDs.removeValue(forKey: id)
            } else {
                // The ordinary pass writes the target; the app's zoom may
                // still overwrite it. Keep the window's events suppressed and
                // check the WindowServer bounds again.
                book.beginVerifying(id)
                var entry = Verification(
                    action: resolution.action, outcome: outcome, settle: resolution.settle, target: target,
                    verifier: NativeZoomVerifier(target: target, before: actualFrame ?? .zero), writeFailed: false
                )
                entry.generation = (verifications[id]?.generation ?? 0) + 1
                verifications[id] = entry
            }
        }
        pending = rest
    }

    /// Zooms whose window is no longer laid out on a display: nothing to judge.
    public func dropUnjudged(_ pending: [NativeZoomResolution]) {
        for resolution in pending {
            log(
                resolution.id, action: resolution.action, outcome: .fallback(.notVisible),
                milliseconds: resolution.settle.milliseconds
            )
            context.invalidateTrust(resolution.id)
            context.setPhysicalFrame(resolution.id, nil)
        }
    }

    /// Decide whether this maximize toggle uses the app's own zoom and, when
    /// it does, take the window out of Gio's writes. Cheap rules first; one AX
    /// round trip for the zoom button; one WindowServer lookup for the window
    /// to watch. Anything short of a certain zoom leaves the ordinary path.
    public func plan(animations: [WindowAnimation], animating: Bool) -> Job? {
        guard let request = pendingRequest else {
            return nil
        }
        pendingRequest = nil
        guard !book.isBusy(request.id) else {
            return nil
        }
        let animation = animations.first { $0.id == request.id }
        let grows = animation.map { $0.duration > 0 && nativeZoomGrows(from: $0.from, to: $0.to) } ?? false
        let enabled = context.isEnabled()
        func skipped(_ reason: NativeZoomSkipReason) -> Job? {
            context.log(
                .debug, "native zoom skipped id=\(request.id.pid):\(request.id.elementID) reason=\(reason.rawValue)"
            )
            return nil
        }
        // The zoom needs the AX motion of the neighbours (a snapshot overlay
        // would fly an image of the window over its own zoom).
        if enabled, request.columnWindowCount == 1, !animating || context.snapshotRendererUsable() {
            return skipped(.noAxMotion)
        }
        if case .ineligible(let reason) = nativeZoomEligibility(
            request, enabled: enabled, grows: grows, zoomAvailable: true
        ) {
            return skipped(reason)
        }
        if case .unavailable(let why) = context.zoomAvailability(request.id) {
            context.log(.debug, "native zoom unavailable id=\(request.id.pid):\(request.id.elementID) why=\(why)")
            log(request.id, action: request.action, outcome: .fallback(.unavailable), milliseconds: 0)
            return nil
        }
        guard let from = context.physicalFrame(request.id) ?? animation?.from else {
            return skipped(.noWindowServer)
        }
        guard let windowID = context.windowServerID(request.id, from) else {
            log(request.id, action: request.action, outcome: .fallback(.noWindowServer), milliseconds: 0)
            return nil
        }
        let start = context.windowServerBounds(windowID) ?? from
        book.begin(request.id, action: request.action)
        context.invalidateTrust(request.id)
        return Job(id: request.id, action: request.action, windowID: windowID, start: start)
    }

    /// Press the zoom (on the app's lane, through the reconciler) and watch
    /// the WindowServer bounds until they settle or the settle timeout passes.
    public func start(_ job: Job) {
        let pressed = context.pressZoom(job.id)
        switch nativeZoomPressDisposition(pressed) {
        case .fallbackNow(let settle):
            context.log(.debug, "native zoom press failed id=\(job.id.pid):\(job.id.elementID) result=\(pressed)")
            finish(job.id, settle: settle)
            return
        case .watch:
            // A timeout-class error means the app is busy zooming: keep the
            // window out of Gio's writes and let the settle detection decide.
            if case .pending(let code) = pressed {
                context.log(
                    .debug,
                    "native zoom press pending id=\(job.id.pid):\(job.id.elementID) axerror=\(code.map(String.init) ?? "laneTimeout")"
                )
            }
        }
        windowServerIDs[job.id] = job.windowID
        let began = context.now()
        let box = TrackerBox(NativeZoomSettleTracker(start: job.start))
        let timer = scheduler.makeStrictTimer(
            start: NativeZoomLimits.pollInterval, interval: NativeZoomLimits.pollInterval, leeway: .milliseconds(1)
        ) { [weak self] in
            guard let self, !context.isShuttingDown(), book.isInFlight(job.id) else {
                self?.timers.removeValue(forKey: job.id)?.cancel()
                return
            }
            let bounds = context.windowServerBounds(job.windowID)
            if let settle = box.tracker.observe(bounds, elapsed: context.now() - began) {
                finish(job.id, settle: settle)
            }
        }
        timers[job.id]?.cancel()
        timers[job.id] = timer
    }

    /// Start the verification clock of the zooms judged in this pass, once
    /// the pass has written them. `failed` are the windows whose write failed
    /// or timed out (an app that is busy).
    public func scheduleVerifications(failed: Set<WindowID>) {
        for id in verifications.keys.sorted() where verifications[id]?.scheduled == false {
            verifications[id]?.scheduled = true
            verifications[id]?.writeFailed = failed.contains(id)
            scheduleVerify(id, after: NativeZoomLimits.verifyDelay)
        }
    }

    // MARK: Internals

    /// The zoom ended (settled, timed out or could not be pressed). While a
    /// motion runs its final pass judges it; otherwise one instant pass does.
    private func finish(_ id: WindowID, settle: NativeZoomSettle) {
        timers.removeValue(forKey: id)?.cancel()
        book.finish(id, settle: settle)
        guard !context.isMotionActive(), !context.isFlightActive() else {
            return
        }
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown(), book.hasResolved, !context.isMotionActive() else {
                return
            }
            context.instantReflow()
        }
    }

    private func scheduleVerify(_ id: WindowID, after delay: TimeInterval) {
        guard let generation = verifications[id]?.generation else {
            return
        }
        scheduler.asyncAfter(delay) { [weak self] in
            guard let self, !context.isShuttingDown(), verifications[id]?.generation == generation else {
                return
            }
            verify(id)
        }
    }

    private func verify(_ id: WindowID) {
        guard var entry = verifications[id] else {
            return
        }
        // Gio moved the window elsewhere since (a newer layout): not ours to judge.
        if let physical = context.physicalFrame(id), !entry.writeFailed,
           abs(physical.minX - entry.target.minX) > NativeZoomLimits.acceptTolerance
            || abs(physical.maxX - entry.target.maxX) > NativeZoomLimits.acceptTolerance
            || abs(physical.minY - entry.target.minY) > NativeZoomLimits.acceptTolerance
            || abs(physical.maxY - entry.target.maxY) > NativeZoomLimits.acceptTolerance {
            finishVerification(id, entry, verified: false)
            return
        }
        let bounds = windowServerIDs[id].flatMap { context.windowServerBounds($0) }
        switch entry.verifier.observe(bounds, writeFailed: entry.writeFailed) {
        case .verified:
            finishVerification(id, entry, verified: true)
        case .unverified:
            finishVerification(id, entry, verified: false)
        case .recheck:
            verifications[id] = entry
            scheduleVerify(id, after: NativeZoomLimits.quietPeriod)
        case .reassert(let reason):
            context.log(.info, nativeZoomReassertLogLine(id: id, app: context.appName(id.pid), reason: reason))
            guard let failed = context.reassert(id, entry.target) else {
                finishVerification(id, entry, verified: false)
                return
            }
            context.recordEcho(id, entry.target, context.now())
            context.setPhysicalFrame(id, entry.target)
            entry.writeFailed = failed
            verifications[id] = entry
            scheduleVerify(id, after: NativeZoomLimits.verifyDelay)
        }
    }

    private func finishVerification(_ id: WindowID, _ entry: Verification, verified: Bool) {
        dropVerification(id)
        context.invalidateTrust(id)
        log(
            id, action: entry.action, outcome: entry.outcome, milliseconds: entry.settle.milliseconds,
            errorCode: entry.settle.errorCode, settleMilliseconds: entry.settle.settleMilliseconds, verified: verified
        )
    }

    private func dropVerification(_ id: WindowID) {
        verifications.removeValue(forKey: id)
        windowServerIDs.removeValue(forKey: id)
        book.endVerifying(id)
        // The last verification lifts the zoom hold on the dim.
        context.updateDim()
    }

    private func log(
        _ id: WindowID, action: NativeZoomAction, outcome: NativeZoomOutcome, milliseconds: Int,
        errorCode: Int32? = nil, settleMilliseconds: Int? = nil, verified: Bool? = nil
    ) {
        context.log(
            .info,
            nativeZoomLogLine(
                id: id, app: context.appName(id.pid), action: action, outcome: outcome, milliseconds: milliseconds,
                errorCode: errorCode, settleMilliseconds: settleMilliseconds, verified: verified
            )
        )
    }
}
