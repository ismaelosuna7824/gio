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
    /// SM-12: a newer dispatched pass writes this window; this one left it.
    case superseded
}

/// The progress of one launched lane, shared by its worker thread and the
/// thread that waits for (or collects) it.
final class LaneState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: Value] = [:]
    private var skipped: Set<Int> = []
    private var superseded: Set<WindowID> = []
    private var finished = false
    private var abandoned = false
    private var busy = false
    private var progressAt = DispatchTime.now()
    /// SM-13: while the lane waits for its app claim, the stall clock waits
    /// too: time spent queued behind the app's previous lane is not a stall.
    private var claimDeadline: DispatchTime?

    var isAbandoned: Bool { lock.withLock { abandoned } }

    func complete(_ index: Int, _ value: Value) {
        lock.withLock {
            guard !abandoned else { return }
            results[index] = value
            progressAt = .now()
        }
    }

    /// The lane waits up to `timeout` for its app claim (no stall meanwhile).
    func awaitClaim(upTo timeout: TimeInterval) {
        lock.withLock {
            claimDeadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9))
        }
    }

    /// The lane claimed its app: the stall clock starts now.
    func claimed() {
        lock.withLock {
            claimDeadline = nil
            progressAt = .now()
        }
    }

    /// The app stayed claimed by another lane: nothing of this lane runs.
    func markBusy() {
        lock.withLock { busy = true }
    }

    /// SM-12: a newer pass writes `ids`; their writes not started yet are
    /// left out here.
    func supersede(_ ids: Set<WindowID>) {
        lock.withLock { superseded.formUnion(ids) }
    }

    /// True (and recorded) when `item` was superseded before it started.
    func skipIfSuperseded(_ item: WriteItem) -> Bool {
        lock.withLock {
            guard superseded.contains(item.id) else { return false }
            skipped.insert(item.index)
            return true
        }
    }

    func finish() {
        lock.withLock { finished = true }
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// (still running, last progress) or nil when nothing is pending. A lane
    /// still waiting for its claim counts as progressing until the claim
    /// deadline.
    func pendingProgress() -> DispatchTime? {
        lock.withLock { finished || abandoned ? nil : max(progressAt, claimDeadline ?? progressAt) }
    }

    func abandonIfStalled(after timeout: TimeInterval) {
        lock.withLock {
            guard !finished, !abandoned, claimDeadline == nil else { return }
            if progressAt.uptimeNanoseconds + UInt64(timeout * 1e9) <= DispatchTime.now().uptimeNanoseconds {
                abandoned = true
            }
        }
    }

    func outcome(of item: WriteItem) -> LaneItemResult<Value> {
        lock.withLock {
            if let value = results[item.index] {
                return .completed(value)
            }
            if skipped.contains(item.index) {
                return .superseded
            }
            return busy ? .skippedBusy : .timedOut
        }
    }
}

/// Lanes started by `LaneExecutor.launch`; `await` gathers them.
final class LaunchedLanes<Value: Sendable>: @unchecked Sendable {
    let lanes: [WriteLane]
    let states: [LaneState<Value>]
    fileprivate let events = DispatchSemaphore(value: 0)

    fileprivate init(lanes: [WriteLane]) {
        self.lanes = lanes
        states = lanes.map { _ in LaneState<Value>() }
    }

    /// Every lane finished (nothing left to wait for).
    var isFinished: Bool {
        states.allSatisfy(\.isFinished)
    }

    /// Wait until every lane finished or made no progress for
    /// `stallTimeout` (abandoned: its unfinished windows time out). Waiting
    /// for the app claim is not a stall: the lane either wins it and writes
    /// or gives up at its claim deadline (`skippedBusy`). One result per
    /// item index.
    func await(stallTimeout: TimeInterval) -> [Int: LaneItemResult<Value>] {
        while true {
            let pending = states.compactMap { $0.pendingProgress() }
            guard let oldest = pending.min() else {
                break
            }
            let deadline = DispatchTime(
                uptimeNanoseconds: oldest.uptimeNanoseconds + UInt64(stallTimeout * 1e9)
            )
            if events.wait(timeout: deadline) == .timedOut {
                for state in states {
                    state.abandonIfStalled(after: stallTimeout)
                }
            }
        }
        var outcome: [Int: LaneItemResult<Value>] = [:]
        for (lane, state) in zip(lanes, states) {
            for item in lane.items {
                outcome[item.index] = state.outcome(of: item)
            }
        }
        return outcome
    }
}

/// Runs lanes and returns one result per item index. Owns the set of pids
/// whose lane (an abandoned one, a motion lane, a dispatched one) has not
/// returned yet, so an app is never written by two overlapping lanes.
final class LaneExecutor: @unchecked Sendable {
    /// Guards `busyPids`; broadcast on every release for `claim(_:waitingUpTo:)`.
    private let released = NSCondition()
    private var busyPids: Set<pid_t> = []

    func run<Value: Sendable>(
        lanes: [WriteLane], mode: LaneConcurrency,
        work: @escaping @Sendable (WriteItem) -> Value
    ) -> [Int: LaneItemResult<Value>] {
        switch mode {
        case .serial:
            var outcome: [Int: LaneItemResult<Value>] = [:]
            for item in lanes.flatMap(\.items).sorted(by: { $0.index < $1.index }) {
                outcome[item.index] = .completed(work(item))
            }
            return outcome
        case .concurrent(let stallTimeout):
            return launch(lanes: lanes, claimWait: nil, work: work).await(stallTimeout: stallTimeout)
        }
    }

    /// Start one concurrent lane per pid and return at once. `claimWait`
    /// nil: an app already claimed is skipped on the spot (`skippedBusy`);
    /// otherwise (SM-12) the lane waits on its own thread up to that long
    /// for the app's previous lane to return. `tails[pid]` runs on the lane
    /// after its writes (not when the lane was abandoned or never claimed
    /// the app). `serial` work runs on the calling thread instead.
    func launch<Value: Sendable>(
        lanes: [WriteLane], claimWait: TimeInterval?, serial: Bool = false,
        tails: [pid_t: @Sendable () -> Void] = [:],
        work: @escaping @Sendable (WriteItem) -> Value
    ) -> LaunchedLanes<Value> {
        let launched = LaunchedLanes<Value>(lanes: lanes)
        let events = launched.events
        for (lane, state) in zip(lanes, launched.states) {
            let tail = tails[lane.pid]
            if serial {
                Self.drain(lane, state: state, work: work, signal: nil)
                tail?()
                state.finish()
                continue
            }
            if claimWait == nil, !claim(lane.pid) {
                state.markBusy()
                state.finish()
                continue
            }
            if let claimWait {
                state.awaitClaim(upTo: claimWait)
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if let claimWait {
                    guard claim(lane.pid, waitingUpTo: claimWait) else {
                        state.markBusy()
                        state.finish()
                        events.signal()
                        return
                    }
                    state.claimed()
                    events.signal()
                }
                Self.drain(lane, state: state, work: work, signal: events)
                if !state.isAbandoned {
                    tail?()
                }
                state.finish()
                release(lane.pid)
                events.signal()
            }
        }
        return launched
    }

    private static func drain<Value: Sendable>(
        _ lane: WriteLane, state: LaneState<Value>, work: (WriteItem) -> Value, signal: DispatchSemaphore?
    ) {
        for item in lane.items {
            if state.isAbandoned {
                break
            }
            if state.skipIfSuperseded(item) {
                continue
            }
            state.complete(item.index, work(item))
            signal?.signal()
        }
    }

    func claim(_ pid: pid_t) -> Bool {
        released.withLock { busyPids.insert(pid).inserted }
    }

    /// SM-12: claim `pid`, waiting up to `timeout` for its current holder
    /// (a motion lane, an earlier dispatched lane) to release it.
    func claim(_ pid: pid_t, waitingUpTo timeout: TimeInterval) -> Bool {
        released.lock()
        defer { released.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while busyPids.contains(pid) {
            if !released.wait(until: deadline) {
                break
            }
        }
        return busyPids.insert(pid).inserted
    }

    func release(_ pid: pid_t) {
        released.lock()
        busyPids.remove(pid)
        released.broadcast()
        released.unlock()
    }
}
