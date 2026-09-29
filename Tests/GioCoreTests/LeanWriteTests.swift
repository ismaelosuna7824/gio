import XCTest
@testable import GioCore

/// MO-02: only changed attributes are written, no pre-read or settable
/// probe on the hot path, and parked writes skip the blocking verify.
final class LeanWriteTests: XCTestCase {
    private let base = CGRect(x: 100, y: 50, width: 600, height: 400)

    // MARK: Plan

    func testIdenticalFrameNeedsNoWrite() {
        XCTAssertEqual(planFrameWrite(current: base, target: base.offsetBy(dx: 0.5, dy: -1)), .none)
    }

    func testPositionOnlyWhenSizeUnchanged() {
        let target = base.offsetBy(dx: 300, dy: 0)
        XCTAssertEqual(planFrameWrite(current: base, target: target), .positionOnly)
    }

    func testSizeOnlyWhenPositionUnchanged() {
        let target = CGRect(x: 100, y: 50, width: 500, height: 400)
        XCTAssertEqual(planFrameWrite(current: base, target: target), .sizeOnly)
    }

    func testGrowingWritesPositionBeforeSize() {
        let target = CGRect(x: 0, y: 0, width: 900, height: 400)
        XCTAssertEqual(planFrameWrite(current: base, target: target), .positionThenSize)
    }

    func testShrinkingWritesSizeBeforePosition() {
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(planFrameWrite(current: base, target: target), .sizeThenPosition)
    }

    // MARK: Writer

    private enum FakeError: Error { case boom }

    private final class FakeIO: FrameAttributeIO {
        var position: CGPoint
        var size: CGSize
        var ops: [String] = []
        var landing: ((CGPoint) -> CGPoint)?
        var vanishOnRead = false

        init(_ frame: CGRect) {
            position = frame.origin
            size = frame.size
        }

        func readPosition() throws -> CGPoint? {
            ops.append("readPosition")
            return vanishOnRead ? nil : position
        }

        func readSize() throws -> CGSize? {
            ops.append("readSize")
            return vanishOnRead ? nil : size
        }

        func writePosition(_ point: CGPoint) throws {
            ops.append("writePosition")
            position = landing?(point) ?? point
        }

        func writeSize(_ newSize: CGSize) throws {
            ops.append("writeSize")
            size = newSize
        }
    }

    func testPositionOnlyWriteIsOneWriteAndOneVerifyRead() throws {
        let io = FakeIO(base)
        try writeFrame(current: base, target: base.offsetBy(dx: 300, dy: 0), verify: true, io: io)
        XCTAssertEqual(io.ops, ["writePosition", "readPosition"])
    }

    func testSizeOnlyWriteIsOneWriteAndOneVerifyRead() throws {
        let io = FakeIO(base)
        let target = CGRect(x: 100, y: 50, width: 500, height: 400)
        try writeFrame(current: base, target: target, verify: true, io: io)
        XCTAssertEqual(io.ops, ["writeSize", "readSize"])
    }

    func testGrowingWriteKeepsPositionFirstOrderAndVerifiesBoth() throws {
        let io = FakeIO(base)
        let target = CGRect(x: 0, y: 0, width: 900, height: 400)
        try writeFrame(current: base, target: target, verify: true, io: io)
        XCTAssertEqual(io.ops, ["writePosition", "writeSize", "readPosition", "readSize"])
    }

    func testShrinkingWriteKeepsSizeFirstOrder() throws {
        let io = FakeIO(base)
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        try writeFrame(current: base, target: target, verify: true, io: io)
        XCTAssertEqual(io.ops, ["writeSize", "writePosition", "readPosition", "readSize"])
    }

    func testUnverifiedWriteNeverReadsBack() throws {
        let io = FakeIO(base)
        try writeFrame(current: base, target: base.offsetBy(dx: 1700, dy: 0), verify: false, io: io)
        XCTAssertEqual(io.ops, ["writePosition"])
    }

    func testNothingToWriteTouchesNothing() throws {
        let io = FakeIO(base)
        try writeFrame(current: base, target: base, verify: true, io: io)
        XCTAssertTrue(io.ops.isEmpty)
    }

    func testVerifyMismatchThrowsWithLandedFrame() {
        let io = FakeIO(base)
        io.landing = { CGPoint(x: $0.x - 50, y: $0.y) }
        XCTAssertThrowsError(
            try writeFrame(current: base, target: base.offsetBy(dx: 300, dy: 0), verify: true, io: io)
        ) { error in
            XCTAssertEqual(error as? FrameWriteError, .mismatch(actual: base.offsetBy(dx: 250, dy: 0)))
        }
    }

    func testVanishedDuringVerifyReportsZeroFrame() {
        let io = FakeIO(base)
        io.vanishOnRead = true
        XCTAssertThrowsError(
            try writeFrame(current: base, target: base.offsetBy(dx: 300, dy: 0), verify: true, io: io)
        ) { error in
            XCTAssertEqual(error as? FrameWriteError, .mismatch(actual: .zero))
        }
    }

    func testWriteErrorsPropagate() {
        final class Failing: FrameAttributeIO {
            func readPosition() throws -> CGPoint? { nil }
            func readSize() throws -> CGSize? { nil }
            func writePosition(_ point: CGPoint) throws { throw FakeError.boom }
            func writeSize(_ size: CGSize) throws {}
        }
        XCTAssertThrowsError(
            try writeFrame(current: base, target: base.offsetBy(dx: 300, dy: 0), verify: true, io: Failing())
        )
    }

    // MARK: Reconciler hand-off

    private final class RecordingActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var reads = 0
        var leanWrites: [(id: WindowID, from: CGRect, verify: Bool)] = []
        var legacyWrites = 0

        func frame(of id: WindowID) throws -> CGRect? {
            reads += 1
            return frames[id]
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            legacyWrites += 1
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            leanWrites.append((id, current, verify))
            frames[id] = frame
        }

        func focus(id: WindowID) throws {}
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    func testReconcilerReadsOncePerWindowAndHandsOverTheFrame() {
        let actuator = RecordingActuator()
        let a = WindowID(pid: 10, elementID: 1), b = WindowID(pid: 10, elementID: 2)
        actuator.frames = [a: base, b: base]
        WindowReconciler(actuator: actuator).reconcile(
            frames: [a: base.offsetBy(dx: 300, dy: 0), b: base.offsetBy(dx: 900, dy: 0)],
            focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(actuator.reads, 2)
        XCTAssertEqual(actuator.legacyWrites, 0)
        XCTAssertEqual(actuator.leanWrites.map(\.from), [base, base])
        XCTAssertEqual(actuator.leanWrites.map(\.verify), [true, true])
    }

    func testParkedWritesSkipVerifyAndVisibleWritesKeepIt() {
        let actuator = RecordingActuator()
        let parkedID = WindowID(pid: 10, elementID: 1), visibleID = WindowID(pid: 10, elementID: 2)
        actuator.frames = [parkedID: base, visibleID: base]
        let park = ParkedTarget(
            frame: CGRect(x: 1799, y: 50, width: 600, height: 400), edge: .right, display: display
        )
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [visibleID: base.offsetBy(dx: 300, dy: 0)], parked: [parkedID: park],
            focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.parked, [parkedID])
        XCTAssertEqual(report.applied, [visibleID])
        XCTAssertEqual(actuator.leanWrites.map(\.id), [parkedID, visibleID])
        XCTAssertEqual(actuator.leanWrites.map(\.verify), [false, true])
    }
}
