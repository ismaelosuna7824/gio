import XCTest
@testable import GioCore

/// WC-06: parked writes tolerate macOS clamping, never focus, and settle
/// as `already` on later passes.
final class ParkedReconcileTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    private enum MockError: Error { case frameMismatch }

    /// Mimics the AX actuator: the write lands where `landing` says, and a
    /// landing different from the request throws like frameMismatch.
    private final class ClampingActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var landing: (CGRect) -> CGRect = { $0 }
        var sets: [(WindowID, CGRect)] = []
        var focuses: [WindowID] = []

        func frame(of id: WindowID) throws -> CGRect? { frames[id] }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            sets.append((id, frame))
            let landed = landing(frame)
            frames[id] = landed
            if landed != frame {
                throw MockError.frameMismatch
            }
        }

        func focus(id: WindowID) throws { focuses.append(id) }
    }

    private func target(_ frame: CGRect, _ edge: ParkEdge) -> ParkedTarget {
        ParkedTarget(frame: frame, edge: edge, display: display)
    }

    func testExactParkedWriteCountsAsParked() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 100, y: 8, width: 700, height: 984)]
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.parked, [id(1)])
        XCTAssertTrue(report.applied.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testClampedParkedFrameWithinStripIsSuccess() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 100, y: 8, width: 700, height: 984)]
        // macOS keeps a 30pt strip visible instead of 1pt.
        actuator.landing = { CGRect(x: 1770, y: $0.origin.y, width: $0.width, height: $0.height) }
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.parked, [id(1)])
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testClampedParkedFrameIsAlreadyOnNextPass() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 1770, y: 8, width: 700, height: 984)]
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertTrue(actuator.sets.isEmpty)
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
    }

    func testClampBeyondStripIsAFailure() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 100, y: 8, width: 700, height: 984)]
        actuator.landing = { CGRect(x: 1200, y: $0.origin.y, width: $0.width, height: $0.height) }
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failed, [id(1)])
        XCTAssertTrue(report.parked.isEmpty)
    }

    func testSizeChangeIsNotAcceptedAsParked() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 1799, y: 8, width: 500, height: 984)]
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        actuator.landing = { _ in CGRect(x: 1799, y: 8, width: 500, height: 984) }
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failed, [id(1)])
    }

    func testWrongSideIsNotAcceptedAsParked() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: -690, y: 8, width: 700, height: 984)]
        let park = target(CGRect(x: 1799, y: 8, width: 700, height: 984), .right)
        actuator.landing = { _ in CGRect(x: -690, y: 8, width: 700, height: 984) }
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.failed, [id(1)])
    }

    func testCornerParkAcceptsStripInBothAxes() {
        let actuator = ClampingActuator()
        actuator.frames = [id(1): CGRect(x: 1790, y: -970, width: 700, height: 984)]
        let park = target(CGRect(x: 1799, y: -983, width: 700, height: 984), .corner)
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [:], parked: [id(1): park], focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
    }

    func testParkedWritesPrecedeVisibleWritesAndFocusStaysVisible() {
        let actuator = ClampingActuator()
        actuator.frames = [
            id(1): CGRect(x: 0, y: 0, width: 100, height: 100),
            id(2): CGRect(x: 0, y: 0, width: 100, height: 100),
            id(3): CGRect(x: 0, y: 0, width: 100, height: 100),
        ]
        let report = WindowReconciler(actuator: actuator).reconcile(
            frames: [id(1): CGRect(x: 8, y: 8, width: 300, height: 300)],
            parked: [
                id(3): target(CGRect(x: 1799, y: 8, width: 100, height: 100), .right),
                id(2): target(CGRect(x: -99, y: 8, width: 100, height: 100), .left),
            ],
            focused: id(3), // a parked window must never be focused
            currentlyFocused: id(1)
        )
        XCTAssertEqual(actuator.sets.map(\.0), [id(2), id(3), id(1)])
        XCTAssertTrue(actuator.focuses.isEmpty)
        XCTAssertFalse(report.focusChanged)
        XCTAssertEqual(report.applied, [id(1)])
        XCTAssertEqual(report.parked, [id(2), id(3)])
    }

    func testParkedWriteIsEchoForGate() {
        var gate = WriteEchoGate()
        let frame = CGRect(x: 1799, y: 8, width: 700, height: 984)
        gate.recordApplied([id(1): frame], at: 0)
        XCTAssertTrue(gate.isEcho(id(1), observed: frame, at: 5))
    }
}
