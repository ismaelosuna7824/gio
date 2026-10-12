import CoreGraphics
import Foundation

/// TG-03: hands each gesture step's frames to the windows through a
/// `MotionFrameSink` (the session's `WindowReconciler`, so invariant 3
/// holds: the reconciler owns every write). Like `MotionPlayer.tick`, but
/// driven by the fingers instead of a clock: every changed window goes to its
/// app's Accessibility motion lane, one submission per app per step (latest
/// frame wins). Origins round to whole points; a change within the writer's
/// tolerance is not written. Not thread-safe: session queue only.
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
        var lanes: [pid_t: [MotionWrite]] = [:]
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
                lanes[id.pid, default: []].append(MotionWrite(id: id, from: last, to: frame))
            }
        }
        var written: [WindowID: CGRect] = [:]
        for pid in lanes.keys.sorted() where sink.submitMotion(pid: pid, writes: lanes[pid]!) {
            for write in lanes[pid]! {
                written[write.id] = write.to
                submitted[write.id] = write.to
            }
            pids.insert(pid)
        }
        return written
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > frameWriteTolerance || abs(a.origin.y - b.origin.y) > frameWriteTolerance
            || abs(a.width - b.width) > frameWriteTolerance || abs(a.height - b.height) > frameWriteTolerance
    }
}
