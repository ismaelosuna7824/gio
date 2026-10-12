import CoreGraphics
import Foundation
import GioCore

/// FI-05 / PA-04 render verification: ~150 ms after a settle that wrote
/// visible windows, compare the frames the settle already read or verified
/// with the on-screen WindowServer list (no AX read, no all-Spaces
/// snapshot). A mismatch gets one repair chain per window per settle, each
/// step re-checked 100 ms later. TG-05: a window the WindowServer draws away
/// from its app's frame first moves there through SkyLight (when usable);
/// then (or without SkyLight, or for a window not drawn at all) a corrective
/// position nudge, and PF-C: a failed position nudge escalates once to a
/// size nudge, and only a failed size nudge makes the window
/// render-unverifiable. Session queue only. Logs carry app names, never
/// titles.
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
        /// TG-05: SkyLight is usable (`[behavior] skylight`, symbols, probe).
        public var windowServerAvailable: () -> Bool
        /// TG-05: moves windows through SkyLight to the frames their apps
        /// report, through the reconciler; the windows moved.
        public var alignWindowServer: ([WindowID: CGRect]) -> Set<WindowID>
        /// A frame Gio just wrote, so its echo events are dropped.
        public var recordEcho: (WindowID, CGRect, TimeInterval) -> Void
        public var appName: (pid_t) -> String
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            isShuttingDown: @escaping () -> Bool, isMotionActive: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isMouseDown: @escaping () -> Bool,
            isReady: @escaping () -> Bool, visibleTargets: @escaping () -> [WindowID: CGRect],
            viewports: @escaping () -> [CGRect], serverWindows: @escaping () -> [ServerWindow],
            nudge: @escaping ([WindowID: [CGRect]]) -> [WindowID],
            windowServerAvailable: @escaping () -> Bool,
            alignWindowServer: @escaping ([WindowID: CGRect]) -> Set<WindowID>,
            recordEcho: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            appName: @escaping (pid_t) -> String, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
            self.windowServerAvailable = windowServerAvailable
            self.alignWindowServer = alignWindowServer
            self.recordEcho = recordEcho
            self.appName = appName
            self.log = log
            self.now = now
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
            context.log(
                book.mismatchLevel(for: mismatch.id),
                renderMismatchLine(id: mismatch.id, app: context.appName(mismatch.id.pid), ax: mismatch.ax, ws: mismatch.ws)
            )
        }
        // One repair chain per window per settle: SkyLight first for a window
        // drawn away from its app's frame (TG-05), else the position nudge.
        let claimed = Set(book.claimNudges(mismatches.map(\.id)))
        let plan = planRenderRepairs(
            mismatches.filter { claimed.contains($0.id) }, windowServer: context.windowServerAvailable()
        )
        var stages: [WindowID: RepairStage] = [:]
        if !plan.windowServer.isEmpty {
            let moved = context.alignWindowServer(plan.windowServer)
            for id in moved where plan.windowServer[id] != nil {
                stages[id] = .windowServer
            }
        }
        // What SkyLight did not move is nudged at once, like the rest.
        let refused = plan.windowServer.keys.filter { stages[$0] == nil }
        let nudged = nudge(plan.nudge + refused, tier: .position, targets: targets)
        for id in nudged {
            stages[id] = .nudge(.position)
        }
        scheduleRecheck(token: token, stages: stages, axFrames: axFrames, targets: targets)
    }

    /// TG-05: the step of a window's repair chain a re-check judges.
    private enum RepairStage: Equatable {
        /// SkyLight moved it to the frame its app reports.
        case windowServer
        /// Accessibility nudge of this tier (FI-05, PF-C).
        case nudge(NudgeTier)
    }

    /// Nudges `ids` at `tier` through the reconciler; the windows written.
    private func nudge(_ ids: [WindowID], tier: NudgeTier, targets: [WindowID: CGRect]) -> [WindowID] {
        let viewports = context.viewports()
        var steps: [WindowID: [CGRect]] = [:]
        for id in ids {
            guard let target = targets[id] else {
                continue
            }
            let viewport = viewports.first { $0.intersects(target) } ?? target
            steps[id] = planNudge(target: target, viewport: viewport, tier: tier)
        }
        guard !steps.isEmpty else {
            return []
        }
        return context.nudge(steps)
    }

    private func scheduleRecheck(
        token: Int, stages: [WindowID: RepairStage], axFrames: [WindowID: CGRect], targets: [WindowID: CGRect]
    ) {
        guard !stages.isEmpty else {
            return
        }
        recordEchoes(Array(stages.keys), targets: targets)
        scheduler.asyncAfter(0.1) { [weak self] in
            self?.recheck(token: token, stages: stages, axFrames: axFrames, targets: targets)
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
        token: Int, stages: [WindowID: RepairStage], axFrames: [WindowID: CGRect], targets: [WindowID: CGRect]
    ) {
        guard mayRun(token) else {
            return
        }
        let ids = Set(stages.keys)
        let still = Set(
            verdict(axFrames: axFrames.filter { ids.contains($0.key) }, targets: targets.filter { ids.contains($0.key) })
                .mismatches.map(\.id)
        )
        var positions: [WindowID] = []
        var sizes: [WindowID] = []
        for id in ids.sorted() {
            let fixed = !still.contains(id)
            let app = context.appName(id.pid)
            switch stages[id]! {
            case .windowServer:
                context.log(fixed ? .info : .warn, renderRepairLine(id: id, app: app, fixed: fixed))
                if !fixed {
                    positions.append(id)
                }
            case .nudge(let tier):
                context.log(fixed ? .info : .warn, renderNudgeLine(id: id, app: app, tier: tier, fixed: fixed))
                if !fixed, tier == .position {
                    sizes.append(id)
                    continue
                }
                markUnverifiableIfFailed(id, fixed: fixed)
            }
        }
        var next: [WindowID: RepairStage] = [:]
        // A failed SkyLight repair falls back to the position nudge; a
        // position nudge it could not write ends the chain quietly, like a
        // first nudge that wrote nothing.
        for id in nudge(positions, tier: .position, targets: targets) {
            next[id] = .nudge(.position)
        }
        let resized = nudge(sizes, tier: .size, targets: targets)
        for id in sizes where !resized.contains(id) {
            markUnverifiableIfFailed(id, fixed: false)
        }
        for id in resized {
            next[id] = .nudge(.size)
        }
        scheduleRecheck(token: token, stages: next, axFrames: axFrames, targets: targets)
    }

    private func markUnverifiableIfFailed(_ id: WindowID, fixed: Bool) {
        if book.recordNudge(id, fixed: fixed) {
            context.log(.debug, renderUnverifiableLine(id: id, app: context.appName(id.pid)))
        }
    }
}
