import Foundation

/// PA-05: the one pending-frame slot of a lane. The session queue offers the
/// newest target for an app; a frame the lane has not started yet is simply
/// overwritten (natural frame dropping). Overwriting merges per window and
/// keeps the OLDEST `from`, so an attribute change of a dropped frame (a
/// shrink on the first frame, FI-03) is never lost.
struct MotionSlot {
    private var pending: [MotionWrite] = []

    var isEmpty: Bool { pending.isEmpty }

    /// Store `writes` as the pending frame. True when a not-yet-started
    /// frame was already waiting (that frame counts as dropped).
    mutating func offer(_ writes: [MotionWrite]) -> Bool {
        let overwrote = !pending.isEmpty
        for write in writes {
            if let index = pending.firstIndex(where: { $0.id == write.id }) {
                pending[index] = MotionWrite(id: write.id, from: pending[index].from, to: write.to)
            } else {
                pending.append(write)
            }
        }
        return overwrote
    }

    /// Move the pending writes into `buffer` (reused by the lane) and empty the slot.
    mutating func take(into buffer: inout [MotionWrite]) {
        buffer.removeAll(keepingCapacity: true)
        swap(&buffer, &pending)
    }

    /// Drop whatever is pending; returns how many window writes were dropped.
    mutating func discard() -> Int {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending.count
    }
}

/// One persistent serial lane per app: created on first use, reused across
/// frames and reflows, torn down when the app goes away. No per-frame worker
/// or group is allocated; the session queue only stores the latest target
/// and schedules the lane when it is idle.
final class MotionLane: @unchecked Sendable {
    let pid: pid_t
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var slot = MotionSlot()
    private var running = false
    private var retired = false
    private var buffer: [MotionWrite] = []
    private var drainBlock: (@Sendable () -> Void)?
    private let write: @Sendable (MotionWrite) -> Void
    private let executor: LaneExecutor
    private let didGoIdle: @Sendable () -> Void

    enum Offer {
        case rejected
        case accepted(started: Bool, overwrote: Bool)
    }

    init(
        pid: pid_t, executor: LaneExecutor, write: @escaping @Sendable (MotionWrite) -> Void,
        didGoIdle: @escaping @Sendable () -> Void
    ) {
        self.pid = pid
        self.executor = executor
        self.write = write
        self.didGoIdle = didGoIdle
        queue = DispatchQueue(label: "gio.motion.lane.\(pid)", qos: .userInteractive)
        // Built once and reused for every activation (strong capture; the
        // cycle is broken by `retire`).
        drainBlock = { [self] in drain() }
    }

    /// `willStart` runs (under the lane lock) right before an idle lane is
    /// scheduled, so the registry's busy count is up before the lane runs.
    func offer(_ writes: [MotionWrite], willStart: () -> Void) -> Offer {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else {
            return .rejected
        }
        if running {
            return .accepted(started: false, overwrote: slot.offer(writes))
        }
        // The app may still be stuck inside an abandoned reconcile lane.
        guard executor.claim(pid) else {
            return .rejected
        }
        running = true
        _ = slot.offer(writes)
        willStart()
        if let block = drainBlock {
            queue.async(execute: block)
        }
        return .accepted(started: true, overwrote: false)
    }

    /// Drop the not-yet-started frame; returns how many window writes went.
    func discardPending() -> Int {
        lock.withLock { slot.discard() }
    }

    /// The app is gone. An in-flight drain finishes on its own.
    func retire() {
        lock.withLock {
            retired = true
            drainBlock = nil
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if slot.isEmpty {
                // Release the app before flipping to idle so the next frame
                // never finds it claimed while the lane claims to be idle.
                executor.release(pid)
                running = false
                lock.unlock()
                break
            }
            slot.take(into: &buffer)
            lock.unlock()
            for item in buffer {
                write(item)
            }
        }
        didGoIdle()
    }
}

/// All persistent lanes of a reconciler plus the cheap busy counter that
/// `waitForIdle` reads: a counter and a condition, not a group per frame.
final class MotionLanes: @unchecked Sendable {
    private let executor: LaneExecutor
    private let book: MotionBook
    private let write: @Sendable (MotionWrite) -> Void
    private let lock = NSLock()
    private var lanes: [pid_t: MotionLane] = [:]
    private let idle = NSCondition()
    private var busy = 0

    init(executor: LaneExecutor, book: MotionBook, write: @escaping @Sendable (MotionWrite) -> Void) {
        self.executor = executor
        self.book = book
        self.write = write
    }

    var count: Int { lock.withLock { lanes.count } }

    func lane(pid: pid_t) -> AnyObject? {
        lock.withLock { lanes[pid] }
    }

    /// False when the app cannot take a frame (an abandoned lane still holds it).
    func submit(pid: pid_t, writes: [MotionWrite]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let lane: MotionLane
        if let existing = lanes[pid] {
            lane = existing
        } else {
            lane = MotionLane(pid: pid, executor: executor, write: write) { [self] in leave() }
            lanes[pid] = lane
        }
        switch lane.offer(writes, willStart: { enter() }) {
        case .rejected:
            return false
        case .accepted(_, let overwrote):
            if overwrote {
                book.recordDrop(pid: pid)
            }
            return true
        }
    }

    func forget(pid: pid_t) {
        lock.withLock { lanes.removeValue(forKey: pid) }?.retire()
    }

    /// Bounded wait until every lane is idle. On timeout the frames still
    /// waiting are discarded: the final pass supersedes them and a stuck app
    /// must not receive stale frames after it.
    func waitForIdle(timeout: TimeInterval) {
        idle.lock()
        let deadline = Date(timeIntervalSinceNow: timeout)
        var timedOut = false
        while busy > 0 {
            if !idle.wait(until: deadline) {
                timedOut = busy > 0
                break
            }
        }
        idle.unlock()
        if timedOut {
            discardPending()
        }
    }

    private func discardPending() {
        let all = lock.withLock { Array(lanes.values) }
        for lane in all where lane.discardPending() > 0 {
            book.recordDrop(pid: lane.pid)
        }
    }

    private func enter() {
        idle.lock()
        busy += 1
        idle.unlock()
    }

    private func leave() {
        idle.lock()
        busy -= 1
        if busy == 0 {
            idle.broadcast()
        }
        idle.unlock()
    }
}
