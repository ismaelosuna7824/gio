import XCTest
@testable import GioCore

/// MO-04: which windows animate, and between which physical frames.
final class MotionPlannerTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1000)
    private let viewport = CGRect(x: 0, y: 0, width: 1800, height: 1000)

    private func column(_ x: CGFloat, width: CGFloat = 800) -> CGRect {
        CGRect(x: x, y: 8, width: width, height: 984)
    }

    private func parkedLeft(width: CGFloat = 800) -> ParkedTarget {
        ParkedTarget(frame: column(-width + parkingSliver, width: width), edge: .left, display: display)
    }

    private func parkedRight(width: CGFloat = 800) -> ParkedTarget {
        ParkedTarget(frame: column(display.maxX - parkingSliver, width: width), edge: .right, display: display)
    }

    private func plan(
        current: [WindowID: CGRect], visible: [WindowID: CGRect] = [:],
        parked: [WindowID: ParkedTarget] = [:]
    ) -> [WindowAnimation] {
        planMotion(
            current: current, visible: visible, parked: parked, viewport: viewport,
            duration: 0.2, easing: .easeOut
        )
    }

    func testOnlyWindowsTouchingTheViewportAnimate() {
        let stayer = id(1), sliding = id(2), farA = id(3), farB = id(4)
        let animations = plan(
            current: [
                stayer: column(8), sliding: column(900),
                farA: parkedLeft().frame, farB: parkedRight().frame,
            ],
            visible: [stayer: column(8), sliding: column(500)],
            parked: [farA: parkedLeft(), farB: parkedRight()]
        )
        XCTAssertEqual(animations.map(\.id), [sliding])
        XCTAssertEqual(animations[0].from, column(900))
        XCTAssertEqual(animations[0].to, column(500))
        XCTAssertEqual(animations[0].duration, 0.2)
    }

    func testWindowEnteringFromParkedStartsAtItsParkedEdge() {
        let entering = id(1)
        let animations = plan(
            current: [entering: parkedRight().frame],
            visible: [entering: column(900)],
            parked: [:]
        )
        XCTAssertEqual(animations.count, 1)
        XCTAssertEqual(animations[0].from, parkedRight().frame)
        XCTAssertEqual(animations[0].to, column(900))
    }

    func testWindowLeavingToParkedAnimatesToItsEdgeThenFinalStepOwnsParking() {
        let leaving = id(1)
        let animations = plan(
            current: [leaving: column(8)],
            parked: [leaving: parkedLeft()]
        )
        XCTAssertEqual(animations.count, 1)
        XCTAssertEqual(animations[0].from, column(8))
        XCTAssertEqual(animations[0].to, parkedLeft().frame)
    }

    func testCornerParkedWindowSlidesOffTheRightEdgeAtItsOwnHeight() {
        let leaving = id(1)
        let corner = ParkedTarget(
            frame: CGRect(x: 1799, y: -983, width: 800, height: 984), edge: .corner, display: display
        )
        let animations = plan(current: [leaving: column(1200)], parked: [leaving: corner])
        XCTAssertEqual(animations[0].to, CGRect(x: 1799, y: 8, width: 800, height: 984))
    }

    func testParkedSliverInsideAnEdgeToEdgeViewportIsNotOnScreen() {
        // The 1pt sliver overlaps an undocked viewport but is still parked.
        let a = id(1), b = id(2)
        let animations = plan(
            current: [a: parkedLeft().frame, b: parkedRight().frame],
            parked: [a: parkedRight(), b: parkedLeft()]
        )
        XCTAssertTrue(animations.isEmpty)
    }

    func testWindowsWithoutAKnownPhysicalFrameJump() {
        let animations = plan(current: [:], visible: [id(1): column(8)])
        XCTAssertTrue(animations.isEmpty)
    }

    func testUnmovedWindowsAreNotAnimated() {
        let animations = plan(current: [id(1): column(8)], visible: [id(1): column(8.4)])
        XCTAssertTrue(animations.isEmpty)
    }

    func testResizeAndScrollAreOneRectInterpolation() {
        let animations = plan(
            current: [id(1): column(8, width: 800)], visible: [id(1): column(408, width: 1200)]
        )
        XCTAssertEqual(animations[0].from.width, 800)
        XCTAssertEqual(animations[0].to.width, 1200)
    }

    func testOutputIsSortedByWindowID() {
        let animations = plan(
            current: [id(9): column(0), id(2): column(0), id(5, pid: 3): column(0)],
            visible: [id(9): column(100), id(2): column(100), id(5, pid: 3): column(100)]
        )
        XCTAssertEqual(animations.map(\.id), [id(5, pid: 3), id(2), id(9)])
    }

    func testMidFlightFramesBecomeTheNextStartWithoutSnapping() {
        // Retargeting is just planning again from sampled frames.
        let first = plan(current: [id(1): column(900)], visible: [id(1): column(500)])[0]
        let mid = first.frame(at: 0.1)
        let retargeted = plan(current: [id(1): mid], visible: [id(1): column(8)])[0]
        XCTAssertEqual(retargeted.from, mid)
        XCTAssertEqual(retargeted.frame(at: 0).origin.x, mid.origin.x)
    }
}
