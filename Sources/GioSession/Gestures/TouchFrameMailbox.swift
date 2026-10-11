import Foundation
import GioCore

/// TG-03: the hand-off from MultitouchSupport's callback thread to the
/// session queue. `post` runs on the callback thread and only copies the
/// frame into a locked buffer (never session state); the first frame of a
/// burst schedules one drain on the session queue, which delivers every
/// frame posted until then, in order. `TouchFrameGate` keeps pointer
/// movement and two-finger scrolling on the callback thread. A drain that
/// falls behind loses the oldest frames past `capacity`, never blocks the
/// callback.
public final class TouchFrameMailbox: @unchecked Sendable {
    /// About two seconds of frames at the trackpad's rate.
    public static let capacity = 256

    /// Guards `pending`, `drainScheduled` and `gate` (callback thread vs
    /// session queue).
    private let lock = NSLock()
    private var pending: [TouchFrame] = []
    private var drainScheduled = false
    private var gate = TouchFrameGate(minimumFingers: 0)
    private let scheduler: SessionScheduler
    private let deliver: ([TouchFrame]) -> Void

    /// `deliver` runs on the session queue.
    public init(scheduler: SessionScheduler, deliver: @escaping ([TouchFrame]) -> Void) {
        self.scheduler = scheduler
        self.deliver = deliver
    }

    /// Session queue (config applied): the fewest fingers any enabled
    /// gesture needs; 0 lets nothing through.
    public func setMinimumFingers(_ fingers: Int) {
        lock.lock()
        gate.minimumFingers = fingers
        lock.unlock()
    }

    /// Any thread (MultitouchSupport's callback).
    public func post(_ frame: TouchFrame) {
        lock.lock()
        guard gate.admits(frame.contacts.count) else {
            lock.unlock()
            return
        }
        if pending.count >= Self.capacity {
            pending.removeFirst(pending.count - Self.capacity + 1)
        }
        pending.append(frame)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule {
            scheduler.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        lock.lock()
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
        if !frames.isEmpty {
            deliver(frames)
        }
    }
}
