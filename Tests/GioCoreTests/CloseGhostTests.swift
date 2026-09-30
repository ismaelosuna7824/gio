import CoreGraphics
import XCTest
@testable import GioCore

final class CloseGhostTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 200, width: 900, height: 700)
    private let viewport = CGRect(x: 0, y: 20, width: 1800, height: 1129)

    private func decide(
        enabled: Bool = true, minimized: Bool = false, physical: CGRect? = nil,
        cached: CGRect? = nil, capturedAt: TimeInterval? = 100, now: TimeInterval = 110
    ) -> CGRect? {
        closeGhostFrame(
            enabled: enabled, isMinimized: minimized, physical: physical ?? frame,
            cachedFrame: cached ?? frame, capturedAt: capturedAt, viewports: [viewport], now: now
        )
    }

    func testFreshImageOfAWindowInViewShowsAGhostAtItsFrame() {
        XCTAssertEqual(decide(), frame)
        XCTAssertEqual(decide(cached: frame.offsetBy(dx: 1.5, dy: -1)), frame, "within 2 pt")
    }

    func testDisabledShowsNothing() {
        XCTAssertNil(decide(enabled: false))
    }

    func testMinimizedWindowShowsNothing() {
        XCTAssertNil(decide(minimized: true))
    }

    func testNoImageShowsNothing() {
        XCTAssertNil(closeGhostFrame(
            enabled: true, isMinimized: false, physical: frame, cachedFrame: nil, capturedAt: nil,
            viewports: [viewport], now: 1
        ))
        XCTAssertNil(closeGhostFrame(
            enabled: true, isMinimized: false, physical: nil, cachedFrame: frame, capturedAt: 1,
            viewports: [viewport], now: 1
        ))
    }

    func testImageOfAnotherFrameIsStale() {
        XCTAssertNil(decide(cached: frame.offsetBy(dx: 40, dy: 0)))
        XCTAssertNil(decide(cached: CGRect(x: 100, y: 200, width: 600, height: 700)))
    }

    func testOldImageIsStale() {
        XCTAssertNil(decide(capturedAt: 0, now: closeGhostMaxImageAge + 1))
    }

    func testParkedOrOffScreenWindowShowsNothing() {
        let parked = CGRect(x: 1799, y: 200, width: 900, height: 700)
        XCTAssertNil(decide(physical: parked, cached: parked))
    }

    func testGhostShrinksAboutSixPercentInAboutOneHundredFiftyMilliseconds() {
        XCTAssertEqual(closeGhostDuration, 0.15, accuracy: 0.001)
        XCTAssertEqual(closeGhostShrink, 0.06, accuracy: 0.001)
    }
}
