import Foundation
import GioCore

/// WS-02: window-server notifications as a backstop for the Accessibility
/// observers. `post` runs on the main thread (SkyLight's callback) and only
/// queues the event; the session queue handles it. A window Gio has not
/// registered `arrivalGrace` after it appeared gets its app scanned (the
/// observer missed it or the app refused one); a registered window that went
/// away gets the proof scan of its app (rule 10: the event purges nothing).
/// The window numbers come from `noteRegistered` at registration. Session
/// queue only, except `post`.
public final class WindowServerWatcher: @unchecked Sendable {
    public struct Context {
        /// Owner of a window-server window, nil once it is gone.
        public var windowOwner: (UInt32) -> WindowServerWindowOwner?
        public var ownPID: pid_t
        public var allowsWindowWork: () -> Bool
        /// Register the app's windows (a pid-only scan) and reflow.
        public var scanApp: (pid_t) -> Void
        public var proveVanished: (WindowID) -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            windowOwner: @escaping (UInt32) -> WindowServerWindowOwner?, ownPID: pid_t,
            allowsWindowWork: @escaping () -> Bool, scanApp: @escaping (pid_t) -> Void,
            proveVanished: @escaping (WindowID) -> Void, log: @escaping (LogLevel, String) -> Void
        ) {
            self.windowOwner = windowOwner
            self.ownPID = ownPID
            self.allowsWindowWork = allowsWindowWork
            self.scanApp = scanApp
            self.proveVanished = proveVanished
            self.log = log
        }
    }

    /// Long enough for the Accessibility path, retries included
    /// (`WindowRegistrationRetry`), to register a window first.
    public static let arrivalGrace: TimeInterval = 1.5

    private let context: Context
    private let scheduler: SessionScheduler
    private var book = WindowNumberBook()
    private var arrivals: [UInt32] = []
    /// Guards `pending` and `drainScheduled` (main thread vs session queue).
    private let lock = NSLock()
    private var pending: [WindowServerEvent] = []
    private var drainScheduled = false

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    /// Any thread.
    public func post(_ event: WindowServerEvent) {
        lock.lock()
        pending.append(event)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule {
            scheduler.async { [weak self] in
                self?.drain()
            }
        }
    }

    public func noteRegistered(_ id: WindowID, number: UInt32) {
        book.record(id, number: number)
    }

    public func forget(_ id: WindowID) {
        book.forget(id)
    }

    private func drain() {
        lock.lock()
        let events = pending
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
        for event in events {
            handle(event)
        }
    }

    private func handle(_ event: WindowServerEvent) {
        switch windowServerEventAction(event, book: book) {
        case .checkArrival(let number):
            let first = arrivals.isEmpty
            arrivals.append(number)
            if first {
                scheduler.asyncAfter(Self.arrivalGrace) { [weak self] in
                    self?.checkArrivals()
                }
            }
        case .proveVanished(let id):
            context.log(.debug, "window server destroyed id=\(id.pid):\(id.elementID)")
            context.proveVanished(id)
        case .ignore:
            return
        }
    }

    private func checkArrivals() {
        let numbers = arrivals
        arrivals.removeAll()
        guard context.allowsWindowWork() else {
            return
        }
        var pids: [pid_t] = []
        for number in numbers {
            if let pid = windowServerArrivalScanPID(
                number: number, book: book, owner: context.windowOwner(number), ownPID: context.ownPID
            ), !pids.contains(pid) {
                pids.append(pid)
            }
        }
        for pid in pids {
            context.log(.info, "window server scan pid=\(pid) reason=unregistered")
            context.scanApp(pid)
        }
    }
}
