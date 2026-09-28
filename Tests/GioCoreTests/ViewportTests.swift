import XCTest
@testable import GioCore

final class ViewportTests: XCTestCase {
    func testClampedKeepsOffsetInsideBounds() {
        XCTAssertEqual(Viewport(offset: 100, width: 1000).clamped(contentWidth: 1232).offset, 100)
        XCTAssertEqual(Viewport(offset: 500, width: 1000).clamped(contentWidth: 1232).offset, 232)
        XCTAssertEqual(Viewport(offset: -50, width: 1000).clamped(contentWidth: 1232).offset, 0)
        XCTAssertEqual(Viewport(offset: 900, width: 1000).clamped(contentWidth: 724).offset, 0)
    }

    func testClampedSanitizesDegenerateInput() {
        XCTAssertEqual(Viewport(offset: .nan, width: 1000).clamped(contentWidth: 1232).offset, 0)
        XCTAssertEqual(Viewport(offset: 300, width: 0).clamped(contentWidth: 1232).offset, 0)
    }

    func testEnsureVisibleLeavesVisibleRangesAlone() {
        let viewport = Viewport(offset: 100, width: 1000)
        XCTAssertEqual(viewport.ensureVisible(range: 200..<400, contentWidth: 2000), viewport)
        XCTAssertEqual(viewport.ensureVisible(range: 100..<1100, contentWidth: 2000), viewport)
    }

    func testEnsureVisibleScrollsMinimally() {
        let viewport = Viewport(offset: 500, width: 1000)
        XCTAssertEqual(
            viewport.ensureVisible(range: 100..<300, contentWidth: 2000).offset, 100
        )
        XCTAssertEqual(
            viewport.ensureVisible(range: 1400..<1700, contentWidth: 2000).offset, 700
        )
    }

    func testEnsureVisibleNeverLeavesBounds() {
        let viewport = Viewport(offset: 0, width: 1000)
        XCTAssertEqual(
            viewport.ensureVisible(range: 1500..<2000, contentWidth: 2000).offset, 1000
        )
        XCTAssertEqual(
            viewport.ensureVisible(range: 0..<2500, contentWidth: 2000).offset, 0
        )
    }
}
