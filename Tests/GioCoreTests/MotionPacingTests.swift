import XCTest
@testable import GioCore

/// PA-03: the motion timer follows the refresh rate of the display that holds
/// the moving windows, never faster than 120 Hz.
final class MotionPacingTests: XCTestCase {
    func testFrameIntervalTable() {
        XCTAssertEqual(frameInterval(for: 60), 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: 120), 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: 90), 1.0 / 90, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: 30), 1.0 / 30, accuracy: 1e-12)
    }

    func testFrameIntervalClampsToSaneRate() {
        // ProMotion tops out at 120: faster panels are not chased.
        XCTAssertEqual(frameInterval(for: 144), 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: 240), 1.0 / 120, accuracy: 1e-12)
        // Unknown or nonsensical rates fall back to 60 Hz; very low rates
        // still tick at 30 so motion never crawls.
        XCTAssertEqual(frameInterval(for: 0), 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: -1), 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(frameInterval(for: 24), 1.0 / 30, accuracy: 1e-12)
    }

    private func flight(_ x: CGFloat) -> WindowAnimation {
        WindowAnimation(
            id: WindowID(pid: 1, elementID: UInt64(x)),
            from: CGRect(x: x, y: 0, width: 100, height: 100),
            to: CGRect(x: x + 50, y: 0, width: 100, height: 100), duration: 0.2, easing: .linear
        )
    }

    func testRefreshRateIsThatOfTheDisplayHoldingTheWindows() {
        let laptop = DisplayRefresh(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), framesPerSecond: 120)
        let external = DisplayRefresh(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), framesPerSecond: 60)
        XCTAssertEqual(motionRefreshRate(animations: [flight(1100)], displays: [laptop, external]), 60)
        XCTAssertEqual(motionRefreshRate(animations: [flight(100)], displays: [laptop, external]), 120)
    }

    func testWindowsOnTwoDisplaysUseTheFasterOne() {
        let laptop = DisplayRefresh(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), framesPerSecond: 120)
        let external = DisplayRefresh(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), framesPerSecond: 60)
        XCTAssertEqual(motionRefreshRate(animations: [flight(100), flight(1100)], displays: [laptop, external]), 120)
    }

    func testUnknownDisplayFallsBackTo60() {
        XCTAssertEqual(motionRefreshRate(animations: [flight(100)], displays: []), 60)
        let far = DisplayRefresh(frame: CGRect(x: 5000, y: 0, width: 100, height: 100), framesPerSecond: 120)
        XCTAssertEqual(motionRefreshRate(animations: [flight(100)], displays: [far]), 60)
    }
}
