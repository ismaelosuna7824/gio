import CoreGraphics
import Foundation

/// TG-03: hands each gesture step's frames to the windows through a
/// `MotionFrameSink` (the session's `WindowReconciler`, so invariant 3
/// holds: the reconciler owns every write). Like `MotionPlayer.tick`, but
/// driven by the fingers instead of a clock: every changed window goes into
/// one WindowServer transaction first (a strip that moves as one piece),
/// what the WindowServer did not take goes to its app's Accessibility lane
/// (latest frame wins). Origins round to whole points; a change within the
/// writer's tolerance is not written. Not thread-safe: session queue only.
public final class GestureFramePump {
    private let sink: MotionFrameSink
    private var submitted: [WindowID: CGRect]
    /// Apps that received a frame (their moved events are our own echoes).
    public private(set) var pids: Set<pid_t> = []

    /// `start`: where each window is now (its physical frame); a window
    /// without one is taken to be at its first target.
    public init(sink: MotionFrameSink, start: [WindowID: CGRect]) {
        self.sink = sink
        submitted = start
    }

    /// One step. Returns the frames the windows are being moved to.
    public func pump(_ targets: [WindowID: CGRect]) -> [WindowID: CGRect] {
        var writes: [MotionWrite] = []
        for id in targets.keys.sorted() {
            let target = targets[id]!
            let frame = CGRect(
                origin: CGPoint(x: target.origin.x.rounded(), y: target.origin.y.rounded()), size: target.size
            )
            guard let last = submitted[id] else {
                submitted[id] = frame
                continue
            }
            if differs(frame, last) {
                writes.append(MotionWrite(id: id, from: last, to: frame))
            }
        }
        guard !writes.isEmpty else {
            return [:]
        }
        var written: [WindowID: CGRect] = [:]
        let moved = sink.submitWindowServerMotion(writes)
        var lanes: [pid_t: [MotionWrite]] = [:]
        for write in writes {
            if moved.contains(write.id) {
                written[write.id] = write.to
            } else {
                lanes[write.id.pid, default: []].append(write)
            }
        }
        for pid in lanes.keys.sorted() where sink.submitMotion(pid: pid, writes: lanes[pid]!) {
            for write in lanes[pid]! {
                written[write.id] = write.to
            }
        }
        for (id, frame) in written {
            submitted[id] = frame
            pids.insert(id.pid)
        }
        return written
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > frameWriteTolerance || abs(a.origin.y - b.origin.y) > frameWriteTolerance
            || abs(a.width - b.width) > frameWriteTolerance || abs(a.height - b.height) > frameWriteTolerance
    }
}
