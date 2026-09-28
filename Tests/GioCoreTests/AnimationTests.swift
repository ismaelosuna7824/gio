import XCTest
@testable import GioCore

/// Plan §24: easing curves, clamping, rect flights, completion.
final class AnimationTests: XCTestCase {
    func testEasingEndpoints() {
        for easing: AnimationEasing in [.linear, .easeOut, .easeInOut] {
            XCTAssertEqual(eased(0, easing: easing), 0)
            XCTAssertEqual(eased(1, easing: easing), 1)
        }
        XCTAssertEqual(eased(0.5, easing: .linear), 0.5)
        XCTAssertEqual(eased(0.5, easing: .easeInOut), 0.5, accuracy: 1e-12)
        XCTAssertEqual(eased(0.5, easing: .easeOut), 0.875, accuracy: 1e-12)
    }

    func testEasingClampsAndSanitizes() {
        XCTAssertEqual(eased(-2, easing: .easeOut), 0)
        XCTAssertEqual(eased(9, easing: .easeOut), 1)
        XCTAssertEqual(eased(.nan, easing: .easeInOut), 0)
    }

    func testLerp() {
        XCTAssertEqual(lerp(10, 20, progress: 0.25), 12.5)
        XCTAssertEqual(lerp(10, 20, progress: 2), 20)
        XCTAssertEqual(lerp(10, 20, progress: .nan), 10)
    }

    func testFlightInterpolates() {
        let flight = WindowAnimation(
            id: WindowID(pid: 1, elementID: 1),
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            to: CGRect(x: 200, y: 100, width: 300, height: 200),
            duration: 1.0,
            easing: .linear
        )
        XCTAssertEqual(flight.frame(at: 0), flight.from)
        XCTAssertEqual(
            flight.frame(at: 0.5),
            CGRect(x: 100, y: 50, width: 200, height: 150)
        )
        XCTAssertEqual(flight.frame(at: 1.0), flight.to)
        XCTAssertEqual(flight.frame(at: 99), flight.to)
        XCTAssertFalse(flight.isComplete(at: 0.5))
        XCTAssertTrue(flight.isComplete(at: 1.0))
    }

    func testZeroDurationCompletesInstantly() {
        let flight = WindowAnimation(
            id: WindowID(pid: 1, elementID: 1),
            from: CGRect(x: 0, y: 0, width: 10, height: 10),
            to: CGRect(x: 50, y: 50, width: 20, height: 20),
            duration: 0
        )
        XCTAssertEqual(flight.frame(at: 0), flight.to)
        XCTAssertTrue(flight.isComplete(at: 0))
    }

    func testBatchSamplesIndependently() {
        let first = WindowAnimation(
            id: WindowID(pid: 1, elementID: 1),
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            to: CGRect(x: 100, y: 0, width: 100, height: 100),
            duration: 0.5,
            easing: .linear
        )
        let second = WindowAnimation(
            id: WindowID(pid: 1, elementID: 2),
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            to: CGRect(x: 0, y: 200, width: 100, height: 100),
            duration: 2.0,
            easing: .linear
        )
        XCTAssertEqual(first.frame(at: 0.5), first.to)
        XCTAssertTrue(first.isComplete(at: 0.5))
        XCTAssertEqual(second.frame(at: 0.5).origin.y, 50)
        XCTAssertFalse(second.isComplete(at: 0.5))
    }
}
