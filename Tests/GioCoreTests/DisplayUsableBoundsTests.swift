import XCTest
@testable import GioCore

final class DisplayUsableBoundsTests: XCTestCase {
    func testMenuAndDockInsetsMapToTopLeftAcrossOffsetDisplays() {
        let screen = CGRect(x: 1440, y: -200, width: 1200, height: 900)
        let visible = CGRect(x: 1440, y: -160, width: 1200, height: 835)
        let cg = CGRect(x: 1440, y: 200, width: 1200, height: 900)
        XCTAssertEqual(DisplayUsableBounds.convert(screenFrame: screen, visibleFrame: visible,
                                                     displayBounds: cg),
                       CGRect(x: 1440, y: 225, width: 1200, height: 835))
    }

    func testRejectsOutOfBoundsAndNonFiniteFrames() {
        let full = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(DisplayUsableBounds.convert(screenFrame: full,
            visibleFrame: CGRect(x: -1, y: 0, width: 100, height: 100), displayBounds: full))
        XCTAssertNil(DisplayUsableBounds.convert(screenFrame: full, visibleFrame: full,
            displayBounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)))
        XCTAssertNil(DisplayUsableBounds.convert(screenFrame: full, visibleFrame: full,
            displayBounds: CGRect(x: 0, y: 0, width: 99, height: 100)))
    }
}
