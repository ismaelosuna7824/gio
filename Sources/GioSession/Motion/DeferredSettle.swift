import Foundation
import GioCore

/// PF-A: the final pass leaves out windows whose app is still busy with a
/// motion write (`ReconcileReport.deferred`) instead of holding the session
/// queue for it. This polls those apps and runs one more final pass once
/// they are idle, or at `deadline` regardless. Deferrals that arrive while
/// polling share that pass; a motion that starts meanwhile settles the
/// windows itself with its own final pass. Session queue only.
public final class DeferredSettle: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 0.03
    /// Past the AX messaging timeout (0.25 s) with room for one more write.
    public static let deadline: TimeInterval = 0.6

    public struct Context {
        public var isBusy: (Set<pid_t>) -> Bool
        public var isMotionActive: () -> Bool
        /// `performReflow(animate: false)`.
        public var finalPass: () -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            isBusy: @escaping (Set<pid_t>) -> Bool, isMotionActive: @escaping () -> Bool,
            finalPass: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void
        ) {
            self.isBusy = isBusy
            self.isMotionActive = isMotionActive
            self.finalPass = finalPass
            self.log = log
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var pids: Set<pid_t> = []
    private var waited: TimeInterval = 0

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    public func `defer`(_ ids: [WindowID]) {
        guard !ids.isEmpty else {
            return
        }
        let polling = !pids.isEmpty
        pids.formUnion(ids.map(\.pid))
        context.log(.debug, "settle deferred windows=\(ids.count) apps=\(pids.count)")
        if !polling {
            waited = 0
            schedulePoll()
        }
    }

    private func schedulePoll() {
        scheduler.asyncAfter(Self.pollInterval) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        guard !pids.isEmpty else {
            return
        }
        if context.isMotionActive() {
            pids = []
            return
        }
        waited += Self.pollInterval
        let busy = context.isBusy(pids)
        if busy, waited < Self.deadline {
            schedulePoll()
            return
        }
        if busy {
            context.log(.info, "settle deferred timeout apps=\(pids.count) ms=\(Int((waited * 1000).rounded()))")
        }
        pids = []
        context.finalPass()
    }
}
