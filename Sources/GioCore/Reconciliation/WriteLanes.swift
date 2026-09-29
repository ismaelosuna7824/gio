import CoreGraphics
import Dispatch
import Foundation

/// One window write the reconciler has to consider. `index` is its place in
/// the deterministic serial order (parked first, then visible, each sorted
/// by ID); the report is always assembled in that order.
public struct WriteItem: Equatable, Sendable {
    public let index: Int
    public let id: WindowID
    public let desired: CGRect
    public let parked: ParkedTarget?
}

/// All writes for one application. AX calls to different processes are
/// independent, so lanes may run concurrently; inside a lane the order is
/// fixed (parked before visible, sorted by ID).
public struct WriteLane: Equatable, Sendable {
    public let pid: pid_t
    public let items: [WriteItem]
}

/// Pure lane planning (MO-03). Windows in `parked` are written as parked and
/// never as visible, exactly like the serial reconciler did.
public func planWriteLanes(
    frames: [WindowID: CGRect], parked: [WindowID: ParkedTarget]
) -> [WriteLane] {
    var ordered: [WriteItem] = []
    for id in parked.keys.sorted() {
        let target = parked[id]!
        ordered.append(WriteItem(index: ordered.count, id: id, desired: target.frame, parked: target))
    }
    for id in frames.keys.sorted() where parked[id] == nil {
        ordered.append(WriteItem(index: ordered.count, id: id, desired: frames[id]!, parked: nil))
    }
    let byPid = Dictionary(grouping: ordered, by: \.id.pid)
    return byPid.keys.sorted().map { WriteLane(pid: $0, items: byPid[$0]!) }
}

/// How the reconciler executes its lanes.
public enum LaneConcurrency: Equatable, Sendable {
    /// Everything on the calling thread in global sorted order, no timeout.
    case serial
    /// One concurrent lane per pid. A lane that makes no progress for
    /// `stallTimeout` seconds is abandoned: its unfinished windows fail with
    /// "timeout" and the reflow returns without waiting for it.
    case concurrent(stallTimeout: TimeInterval)
}

enum LaneItemResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    /// The app's previous lane is still stuck inside an AX call.
    case skippedBusy
}

/// Runs lanes and returns one result per item index. Owns the set of pids
/// whose abandoned lane has not returned yet, so a hung app is never written
/// by two overlapping lanes.
final class LaneExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var busyPids: Set<pid_t> = []

    private final class LaneState<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Int: Value] = [:]
        private var finished = false
        private var abandoned = false
        private var progressAt = DispatchTime.now()

        var isAbandoned: Bool { lock.withLock { abandoned } }

        func complete(_ index: Int, _ value: Value) {
            lock.withLock {
                guard !abandoned else { return }
                results[index] = value
                progressAt = .now()
            }
        }

        func finish() {
            lock.withLock { finished = true }
        }

        /// (still running, last progress) or nil when nothing is pending.
        func pendingProgress() -> DispatchTime? {
            lock.withLock { finished || abandoned ? nil : progressAt }
        }

        func abandonIfStalled(after timeout: TimeInterval) {
            lock.withLock {
                guard !finished, !abandoned else { return }
                if progressAt.uptimeNanoseconds + UInt64(timeout * 1e9) <= DispatchTime.now().uptimeNanoseconds {
                    abandoned = true
                }
            }
        }

        func snapshot() -> [Int: Value] {
            lock.withLock { results }
        }
    }

    func run<Value: Sendable>(
        lanes: [WriteLane], mode: LaneConcurrency,
        work: @escaping @Sendable (WriteItem) -> Value
    ) -> [Int: LaneItemResult<Value>] {
        var outcome: [Int: LaneItemResult<Value>] = [:]
        switch mode {
        case .serial:
            for item in lanes.flatMap(\.items).sorted(by: { $0.index < $1.index }) {
                outcome[item.index] = .completed(work(item))
            }
        case .concurrent(let stallTimeout):
            let events = DispatchSemaphore(value: 0)
            var launched: [(lane: WriteLane, state: LaneState<Value>)] = []
            for lane in lanes {
                guard claim(lane.pid) else {
                    for item in lane.items {
                        outcome[item.index] = .skippedBusy
                    }
                    continue
                }
                let state = LaneState<Value>()
                launched.append((lane, state))
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    for item in lane.items {
                        if state.isAbandoned {
                            break
                        }
                        state.complete(item.index, work(item))
                        events.signal()
                    }
                    state.finish()
                    release(lane.pid)
                    events.signal()
                }
            }
            while true {
                let pending = launched.compactMap { $0.state.pendingProgress() }
                guard let oldest = pending.min() else {
                    break
                }
                let deadline = DispatchTime(
                    uptimeNanoseconds: oldest.uptimeNanoseconds + UInt64(stallTimeout * 1e9)
                )
                if events.wait(timeout: deadline) == .timedOut {
                    for entry in launched {
                        entry.state.abandonIfStalled(after: stallTimeout)
                    }
                }
            }
            for entry in launched {
                let done = entry.state.snapshot()
                for item in entry.lane.items {
                    outcome[item.index] = done[item.index].map { .completed($0) } ?? .timedOut
                }
            }
        }
        return outcome
    }

    func claim(_ pid: pid_t) -> Bool {
        lock.withLock { busyPids.insert(pid).inserted }
    }

    func release(_ pid: pid_t) {
        lock.withLock { _ = busyPids.remove(pid) }
    }
}
