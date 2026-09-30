import Dispatch
import Foundation

/// A repeating timer handed out by a `SessionScheduler`.
public protocol SessionTimer: AnyObject {
    func cancel()
}

/// Where session components run deferred work: the session queue live, a
/// synchronous virtual clock in tests. Components call it only from the
/// session queue; work always runs there too.
public protocol SessionScheduler: AnyObject, Sendable {
    /// Traps when not on the session queue (live); no-op in tests.
    func assertOnQueue()
    func async(_ work: @escaping @Sendable () -> Void)
    func asyncAfter(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
    /// A `.strict` repeating timer, first firing `start` seconds from now.
    func makeStrictTimer(
        start: TimeInterval, interval: TimeInterval, leeway: DispatchTimeInterval,
        handler: @escaping @Sendable () -> Void
    ) -> SessionTimer
}

public extension SessionScheduler {
    func makeStrictTimer(
        start: TimeInterval, interval: TimeInterval, handler: @escaping @Sendable () -> Void
    ) -> SessionTimer {
        makeStrictTimer(start: start, interval: interval, leeway: .microseconds(500), handler: handler)
    }
}

/// The live scheduler: plain `DispatchQueue` calls on the session queue.
public final class QueueScheduler: SessionScheduler, @unchecked Sendable {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func assertOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    public func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    public func asyncAfter(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func makeStrictTimer(
        start: TimeInterval, interval: TimeInterval, leeway: DispatchTimeInterval,
        handler: @escaping @Sendable () -> Void
    ) -> SessionTimer {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(
            deadline: .now() + start, repeating: .nanoseconds(Int(interval * 1e9)), leeway: leeway
        )
        source.setEventHandler(handler: handler)
        source.resume()
        return DispatchSessionTimer(source)
    }
}

private final class DispatchSessionTimer: SessionTimer {
    private let source: DispatchSourceTimer

    init(_ source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        source.cancel()
    }
}

/// Test scheduler: nothing runs until the test drains or advances the
/// virtual clock. Work runs in deadline order, ties in submission order;
/// work scheduled while advancing runs too when it falls due in the window.
/// Single-threaded by contract.
public final class ManualScheduler: SessionScheduler, @unchecked Sendable {
    public private(set) var now: TimeInterval = 0
    private var entries: [Entry] = []
    private var sequence = 0

    private final class Entry {
        let due: TimeInterval
        let order: Int
        let work: () -> Void

        init(due: TimeInterval, order: Int, work: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.work = work
        }
    }

    public init() {}

    /// Work still waiting (timers count once per pending firing).
    public var pendingCount: Int {
        entries.count
    }

    public func assertOnQueue() {}

    public func async(_ work: @escaping @Sendable () -> Void) {
        enqueue(at: now, work)
    }

    public func asyncAfter(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        enqueue(at: now + delay, work)
    }

    public func makeStrictTimer(
        start: TimeInterval, interval: TimeInterval, leeway: DispatchTimeInterval,
        handler: @escaping @Sendable () -> Void
    ) -> SessionTimer {
        let timer = ManualTimer()
        func arm(at due: TimeInterval) {
            enqueue(at: due) {
                guard !timer.isCancelled else {
                    return
                }
                handler()
                if !timer.isCancelled {
                    arm(at: due + interval)
                }
            }
        }
        arm(at: now + start)
        return timer
    }

    /// Runs everything already due at the current time.
    public func runPending() {
        advance(by: 0)
    }

    /// Moves the clock forward, running due work in order.
    public func advance(by delta: TimeInterval) {
        let target = now + delta
        while let index = nextIndex(dueBy: target) {
            let entry = entries.remove(at: index)
            now = max(now, entry.due)
            entry.work()
        }
        now = target
    }

    private func enqueue(at due: TimeInterval, _ work: @escaping () -> Void) {
        sequence += 1
        entries.append(Entry(due: due, order: sequence, work: work))
    }

    private func nextIndex(dueBy target: TimeInterval) -> Int? {
        var best: Int?
        for (index, entry) in entries.enumerated() where entry.due <= target + 1e-12 {
            if let current = best {
                let other = entries[current]
                if entry.due < other.due || (entry.due == other.due && entry.order < other.order) {
                    best = index
                }
            } else {
                best = index
            }
        }
        return best
    }
}

private final class ManualTimer: SessionTimer {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
