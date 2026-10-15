import CoreGraphics
import Foundation
import GioCore

/// FI-05 / PA-04 render verification: ~150 ms after a settle that wrote
/// visible windows, compare the frames the settle already read or verified
/// with the on-screen WindowServer list (no AX read, no all-Spaces
/// snapshot). A mismatch gets one corrective position nudge per window per
/// settle and a re-check 100 ms later; PF-C: a failed position nudge
/// escalates once to a size nudge, and only a failed size nudge makes the
/// window render-unverifiable. Session queue only. Logs carry app names,
/// never titles.
public final class RenderVerifier: @unchecked Sendable {
    public struct Context {
        public var isShuttingDown: () -> Bool
        public var isMotionActive: () -> Bool
        public var isFlightActive: () -> Bool
        public var isMouseDown: () -> Bool
        /// The session can write (it has a reconciler); checks wait otherwise.
        public var isReady: () -> Bool
        /// The last pass's visible targets.
        public var visibleTargets: () -> [WindowID: CGRect]
        /// Usable frame of every display.
        public var viewports: () -> [CGRect]
        /// On-screen WindowServer windows (Cocoa coordinates), one query per call.
        public var serverWindows: () -> [ServerWindow]
        /// Writes the nudge steps through the reconciler; the windows written.
        public var nudge: ([WindowID: [CGRect]]) -> [WindowID]
        /// A frame Gio just wrote, so its echo events are dropped.
        public var recordEcho: (WindowID, CGRect, TimeInterval) -> Void
        public var appName: (pid_t) -> String
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval
        /// Every WindowServer window of one app, on screen or not (diagnostics).
        public var serverWindowStates: (pid_t) -> [ServerWindowState]

        public init(
            isShuttingDown: @escaping () -> Bool, isMotionActive: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isMouseDown: @escaping () -> Bool,
            isReady: @escaping () -> Bool, visibleTargets: @escaping () -> [WindowID: CGRect],
            viewports: @escaping () -> [CGRect], serverWindows: @escaping () -> [ServerWindow],
            nudge: @escaping ([WindowID: [CGRect]]) -> [WindowID],
            recordEcho: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            appName: @escaping (pid_t) -> String, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            serverWindowStates: @escaping (pid_t) -> [ServerWindowState] = { _ in [] }
        ) {
            self.isShuttingDown = isShuttingDown
            self.isMotionActive = isMotionActive
            self.isFlightActive = isFlightActive
            self.isMouseDown = isMouseDown
            self.isReady = isReady
            self.visibleTargets = visibleTargets
            self.viewports = viewports
            self.serverWindows = serverWindows
            self.nudge = nudge
            self.recordEcho = recordEcho
            self.appName = appName
            self.log = log
            self.now = now
            self.serverWindowStates = serverWindowStates
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var book = RenderCheckBook()
    /// PA-04: windows written or animated since the last render check, and
    /// the frames the settle already read or verified for them.
    private var candidates: Set<WindowID> = []
    private var settled: [WindowID: CGRect] = [:]

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    public var hasCandidates: Bool {
        !candidates.isEmpty
    }

    /// A visible write or a motion frame: check this window after the settle.
    public func insertCandidate(_ id: WindowID) {
        candidates.insert(id)
    }

    /// The frames a settle read or verified, kept for current candidates.
    public func recordSettled(from settledFrames: [WindowID: CGRect]) {
        for id in candidates {
            if let frame = settledFrames[id] {
                settled[id] = frame
            }
        }
    }

    /// A new pass or motion: pending checks must not run.
    public func cancel() {
        book.cancel()
    }

    /// Re-registered or gone windows start clean.
    public func forget(_ ids: some Sequence<WindowID>) {
        book.forget(ids)
    }

    /// ~150 ms after a settle that moved windows.
    public func schedule() {
        let token = book.schedule()
        scheduler.asyncAfter(0.15) { [weak self] in
            self?.run(token: token)
        }
    }

    /// Never while a newer pass superseded the check, a motion is in
    /// flight, a mouse button is down or Gio is leaving.
    private func mayRun(_ token: Int) -> Bool {
        !context.isShuttingDown() && book.isCurrent(token) && !context.isMotionActive()
            && !context.isFlightActive() && !context.isMouseDown()
    }

    private func verdict(axFrames: [WindowID: CGRect], targets: [WindowID: CGRect]) -> RenderVerdict {
        evaluateRender(
            axFrames: axFrames, server: context.serverWindows(), targets: targets, viewports: context.viewports()
        )
    }

    private func run(token: Int) {
        guard mayRun(token), context.isReady() else {
            return
        }
        let visible = context.visibleTargets()
        let axFrames = book.checkable(renderCheckFrames(candidates: candidates, visible: visible, settled: settled))
        candidates = []
        settled = [:]
        // Nothing visible was written in this settle: skip the WindowServer
        // snapshot entirely.
        guard !axFrames.isEmpty else {
            return
        }
        let targets = visible.filter { axFrames[$0.key] != nil }
        let verdict = verdict(axFrames: axFrames, targets: targets)
        for entry in verdict.unmatched {
            context.log(
                .debug,
                renderUnmatchedLine(
                    id: entry.id, app: context.appName(entry.id.pid), reason: entry.reason,
                    candidates: entry.candidates
                )
            )
        }
        let mismatches = verdict.mismatches
        guard !mismatches.isEmpty else {
            return
        }
        for mismatch in mismatches {
            let level = book.mismatchLevel(for: mismatch.id)
            context.log(
                level,
                renderMismatchLine(id: mismatch.id, app: context.appName(mismatch.id.pid), ax: mismatch.ax, ws: mismatch.ws)
            )
            // The on-screen list has nothing of it: where does the server keep it?
            if mismatch.ws == nil {
                context.log(
                    level,
                    renderMissingDetailLine(
                        id: mismatch.id, entries: context.serverWindowStates(mismatch.id.pid),
                        displays: context.viewports()
                    )
                )
            }
        }
        // Corrective nudge through the reconciler, once per window per settle.
        let viewports = context.viewports()
        var steps: [WindowID: [CGRect]] = [:]
        for id in book.claimNudges(mismatches.map(\.id)) {
            guard let target = targets[id] else {
                continue
            }
            let viewport = viewports.first { $0.intersects(target) } ?? target
            steps[id] = planNudge(target: target, viewport: viewport)
        }
        let written = context.nudge(steps)
        guard !written.isEmpty else {
            return
        }
        recordEchoes(written, targets: targets)
        scheduler.asyncAfter(0.1) { [weak self] in
            self?.recheck(token: token, written: written, axFrames: axFrames, targets: targets, tier: .position)
        }
    }

    private func recordEchoes(_ written: [WindowID], targets: [WindowID: CGRect]) {
        let nudgeTime = context.now()
        for id in written {
            if let target = targets[id] {
                context.recordEcho(id, target, nudgeTime)
            }
        }
    }

    private func recheck(
        token: Int, written: [WindowID], axFrames: [WindowID: CGRect], targets: [WindowID: CGRect],
        tier: NudgeTier
    ) {
        guard mayRun(token) else {
            return
        }
        let subset = targets.filter { written.contains($0.key) }
        let still = Set(
            verdict(axFrames: axFrames.filter { written.contains($0.key) }, targets: subset).mismatches.map(\.id)
        )
        let viewports = context.viewports()
        var escalate: [WindowID: [CGRect]] = [:]
        for id in written {
            let fixed = !still.contains(id)
            context.log(
                fixed ? .info : .warn, renderNudgeLine(id: id, app: context.appName(id.pid), tier: tier, fixed: fixed)
            )
            if !fixed, tier == .position, let target = targets[id] {
                let viewport = viewports.first { $0.intersects(target) } ?? target
                escalate[id] = planNudge(target: target, viewport: viewport, tier: .size)
                continue
            }
            markUnverifiableIfFailed(id, fixed: fixed)
        }
        guard !escalate.isEmpty else {
            return
        }
        let resized = context.nudge(escalate)
        for id in escalate.keys where !resized.contains(id) {
            markUnverifiableIfFailed(id, fixed: false)
        }
        guard !resized.isEmpty else {
            return
        }
        recordEchoes(resized, targets: targets)
        scheduler.asyncAfter(0.1) { [weak self] in
            self?.recheck(token: token, written: resized, axFrames: axFrames, targets: targets, tier: .size)
        }
    }

    private func markUnverifiableIfFailed(_ id: WindowID, fixed: Bool) {
        if book.recordNudge(id, fixed: fixed) {
            context.log(.debug, renderUnverifiableLine(id: id, app: context.appName(id.pid)))
        }
    }
}
