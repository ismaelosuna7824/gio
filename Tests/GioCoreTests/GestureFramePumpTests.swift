import CoreGraphics
import XCTest
@testable import GioCore

/// TG-03: each gesture step's frames reach the windows through the motion
/// sink (the reconciler, invariant 3): every changed window on its app's
/// Accessibility motion lane (PF-S: no WindowServer transaction), one
/// submission per app per step, only real changes, whole points.
final class GestureFramePumpTests: XCTestCase {
    private final class Sink: MotionFrameSink {
        var laneAccepts = true
        var laneWrites: [pid_t: [[MotionWrite]]] = [:]

        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            laneWrites[pid, default: []].append(writes)
            return laneAccepts
        }

        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    private let a = WindowID(pid: 10, elementID: 1)
    private let b = WindowID(pid: 10, elementID: 2)
    private let c = WindowID(pid: 20, elementID: 3)
    private let frame = CGRect(x: 100, y: 8, width: 600, height: 784)

    func testOnlyChangedWindowsAreWrittenOnTheirAppsLanes() {
        let sink = Sink()
        let pump = GestureFramePump(sink: sink, start: [a: frame, b: frame, c: frame])
        let written = pump.pump([
            a: frame.offsetBy(dx: -40.4, dy: 0), b: frame.offsetBy(dx: -40, dy: 0), c: frame.offsetBy(dx: 0.6, dy: 0),
        ])
        XCTAssertEqual(sink.laneWrites[10]?.count, 1, "one submission per app for the step")
        XCTAssertEqual(sink.laneWrites[10]?.first?.map(\.id), [a, b])
        XCTAssertEqual(sink.laneWrites[10]?.first?.map(\.to), [
            CGRect(x: 60, y: 8, width: 600, height: 784), CGRect(x: 60, y: 8, width: 600, height: 784),
        ], "origins round to whole points")
        XCTAssertNil(sink.laneWrites[20], "a sub-point change is not written")
        XCTAssertEqual(written, [a: CGRect(x: 60, y: 8, width: 600, height: 784), b: CGRect(x: 60, y: 8, width: 600, height: 784)])
        XCTAssertEqual(pump.pids, [10])
    }

    func testNextStepWritesFromWhereTheLastOneLeftTheWindow() {
        let sink = Sink()
        let pump = GestureFramePump(sink: sink, start: [a: frame])
        _ = pump.pump([a: frame.offsetBy(dx: -40, dy: 0)])
        _ = pump.pump([a: frame.offsetBy(dx: -80, dy: 0)])
        XCTAssertEqual(sink.laneWrites[10]?[1].first?.from, frame.offsetBy(dx: -40, dy: 0))
        XCTAssertTrue(pump.pump([a: frame.offsetBy(dx: -80, dy: 0)]).isEmpty, "nothing moved, nothing written")
        XCTAssertEqual(sink.laneWrites[10]?.count, 2)
    }

    func testABusyLaneKeepsTheOldStartSoTheNextStepCatchesUp() {
        let sink = Sink()
        sink.laneAccepts = false
        let pump = GestureFramePump(sink: sink, start: [c: frame])
        XCTAssertTrue(pump.pump([c: frame.offsetBy(dx: 30, dy: 0)]).isEmpty)
        sink.laneAccepts = true
        let written = pump.pump([c: frame.offsetBy(dx: 60, dy: 0)])
        XCTAssertEqual(sink.laneWrites[20]?.last?.first?.from, frame)
        XCTAssertEqual(written[c], frame.offsetBy(dx: 60, dy: 0))
    }

    func testWindowsWithoutAKnownFrameStartFromTheirTarget() {
        let sink = Sink()
        let pump = GestureFramePump(sink: sink, start: [:])
        XCTAssertTrue(pump.pump([a: frame]).isEmpty, "no known frame: it is taken as already there")
        let written = pump.pump([a: frame.offsetBy(dx: 10, dy: 0)])
        XCTAssertEqual(written[a], frame.offsetBy(dx: 10, dy: 0))
    }
}
