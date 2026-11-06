import CoreGraphics
import Foundation
import GioCore

/// FI-16: windows on screen that no scan registered. A scan that skipped
/// windows of an app (unreadable attributes), a window-server rescue scan
/// that left the window unregistered, and the window server vs registry
/// check (every full scan, at most `auditInterval` apart otherwise) start a
/// per-pid retry series (`StrandedWindowRetryBook`, `delays`). A series
/// ends once the app is read fully with nothing of it stranded, the window
/// server stops listing the window or the app dies; the last attempt gives
/// up and remembers the window. A wake or an unlock rescans everything now
/// and again after `wakeSettleDelays`. Session queue only. Logs carry pids
/// and counts, never titles.
public final class StrandedWindowRescue: @unchecked Sendable {
    public struct Context {
        public var ownPID: pid_t
        public var allowsWindowWork: () -> Bool
        public var isRunning: (pid_t) -> Bool
        /// Pids discovery scans (`.regular` apps).
        public var regularPIDs: () -> Set<pid_t>
        /// On-screen layer-0 windows (one window-server query).
        public var serverWindows: () -> [ServerWindow]
        /// The window numbers recorded for registered windows (WS-04).
        public var registeredNumbers: () -> Set<UInt32>
        /// Scan one app and reflow (its windows are arrivals).
        public var scanApp: (pid_t) -> Void
        /// The debounced full resync.
        public var rescanAll: () -> Void
        public var now: () -> TimeInterval
        public var log: (LogLevel, String) -> Void

        public init(
            ownPID: pid_t, allowsWindowWork: @escaping () -> Bool, isRunning: @escaping (pid_t) -> Bool,
            regularPIDs: @escaping () -> Set<pid_t>, serverWindows: @escaping () -> [ServerWindow],
            registeredNumbers: @escaping () -> Set<UInt32>, scanApp: @escaping (pid_t) -> Void,
            rescanAll: @escaping () -> Void, now: @escaping () -> TimeInterval,
            log: @escaping (LogLevel, String) -> Void
        ) {
            self.ownPID = ownPID
            self.allowsWindowWork = allowsWindowWork
            self.isRunning = isRunning
            self.regularPIDs = regularPIDs
            self.serverWindows = serverWindows
            self.registeredNumbers = registeredNumbers
            self.scanApp = scanApp
            self.rescanAll = rescanAll
            self.now = now
            self.log = log
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var book = StrandedWindowRetryBook()
    /// Whether each pid's latest scan read it fully (false while unknown
    /// after a retry scan that did not report, e.g. a failed list).
    private var readFully: [pid_t: Bool] = [:]
    private var lastAudit: TimeInterval?
    /// The newest wake: older settle rescans find it changed and stay quiet.
    private var wakeGeneration = 0

    /// Diagnostics: retry scans run this session.
    public private(set) var retryScanCount = 0

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    /// Starts the periodic window server check.
    public func start() {
        scheduleAuditTick(after: StrandedWindowRetry.auditInterval)
    }

    /// A discovery scan ended (`DiscoveryService.Context.scanFinished`).
    public func noteScan(_ summary: DiscoveryScanSummary) {
        for pid in summary.completePIDs {
            readFully[pid] = true
            book.noteRead(pid, complete: true)
        }
        for pid in summary.skippedPIDs {
            readFully[pid] = false
            book.noteRead(pid, complete: false)
        }
        if let scope = summary.scope, !summary.completePIDs.contains(scope) {
            readFully[scope] = false
        }
        for pid in summary.skippedPIDs.sorted() where pid != context.ownPID {
            if let step = book.request(pid, reason: .skipped) {
                schedule(step)
            }
        }
        if summary.scope == nil {
            audit()
        }
    }

    /// WS-02: the window server showed a window Gio has not registered after
    /// the grace: scan its app now, and keep asking while it stays stranded.
    public func rescue(_ pid: pid_t) {
        guard pid != context.ownPID else {
            return
        }
        context.scanApp(pid)
        guard context.isRunning(pid), !isResolved(pid), let step = book.request(pid, reason: .unregistered) else {
            return
        }
        schedule(step)
    }

    /// The window server vs registry check.
    public func audit() {
        lastAudit = context.now()
        guard context.allowsWindowWork() else {
            return
        }
        let server = context.serverWindows()
        book.keepRejected(listed: Set(server.compactMap(\.number)))
        readFully = readFully.filter { context.isRunning($0.key) }
        let stranded = strandedServerWindows(
            server, registeredNumbers: context.registeredNumbers(), ownPID: context.ownPID,
            manageablePIDs: context.regularPIDs(), rejected: book.rejected
        )
        for (pid, numbers) in stranded.sorted(by: { $0.key < $1.key }) where context.isRunning(pid) {
            if let step = book.request(pid, reason: .unregistered) {
                context.log(.info, "window server stranded pid=\(pid) windows=\(numbers.count)")
                schedule(step)
            }
        }
    }

    /// FI-15/FI-16: a wake or an unlock. Rescan now, and again once the
    /// screen has settled (the first rescan often meets the unlocking
    /// screen). What gave up behind the lock may answer now.
    public func noteWake(reason: String) {
        book.clearRejected()
        wakeGeneration += 1
        let generation = wakeGeneration
        context.log(.info, "session rescan reason=\(reason)")
        context.rescanAll()
        for delay in StrandedWindowRetry.wakeSettleDelays {
            scheduler.asyncAfter(delay) { [weak self] in
                guard let self, generation == wakeGeneration else {
                    return
                }
                context.log(.info, "session rescan reason=\(reason) settle=\(Int(delay))s")
                context.rescanAll()
            }
        }
    }

    private func stranded(_ pid: pid_t) -> Set<UInt32> {
        let server = context.serverWindows().filter { $0.pid == pid }
        guard !server.isEmpty else {
            return []
        }
        let found = strandedServerWindows(
            server, registeredNumbers: context.registeredNumbers(), ownPID: context.ownPID,
            manageablePIDs: [pid], rejected: book.rejected
        )
        return Set(found[pid] ?? [])
    }

    private func isResolved(_ pid: pid_t) -> Bool {
        readFully[pid] == true && stranded(pid).isEmpty
    }

    private func schedule(_ step: WindowRetryStep) {
        scheduler.asyncAfter(step.delay) { [weak self] in
            self?.attempt(step.pid, step.attempt)
        }
    }

    private func attempt(_ pid: pid_t, _ attempt: Int) {
        guard book.isPending(pid, attempt: attempt), let reason = book.reason(of: pid) else {
            return
        }
        let alive = context.isRunning(pid)
        // Registered or gone meanwhile: no scan.
        if alive, context.allowsWindowWork(), !isResolved(pid) {
            context.log(.info, "window retry scan pid=\(pid) attempt=\(attempt) reason=\(reason.rawValue)")
            retryScanCount += 1
            readFully[pid] = false
            context.scanApp(pid)
        }
        let left = alive ? stranded(pid) : []
        let resolved = alive && readFully[pid] == true && left.isEmpty
        switch book.finish(pid, attempt: attempt, alive: alive, resolved: resolved, stranded: left) {
        case .resolved:
            context.log(.debug, "window retry resolved pid=\(pid) attempts=\(attempt)")
        case .appGone:
            readFully.removeValue(forKey: pid)
            context.log(.debug, "window retry ended pid=\(pid) reason=appGone")
        case .retry(let step):
            schedule(step)
        case .gaveUp(let attempts, let reason):
            context.log(.info, "window retry scan pid=\(pid) gave up attempts=\(attempts) reason=\(reason.rawValue)")
        }
    }

    private func scheduleAuditTick(after delay: TimeInterval) {
        scheduler.asyncAfter(delay) { [weak self] in
            guard let self else {
                return
            }
            let interval = StrandedWindowRetry.auditInterval
            let since = lastAudit.map { context.now() - $0 } ?? interval
            if since >= interval {
                audit()
                scheduleAuditTick(after: interval)
            } else {
                scheduleAuditTick(after: interval - since)
            }
        }
    }
}
