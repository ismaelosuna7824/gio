import CoreGraphics
import XCTest
@testable import GioUI

/// FX-06: the notice sits centred low on the display it is about, like the
/// system's volume HUD, and never leaves that display.
final class NoticePanelTests: XCTestCase {
    func testTheNoticeIsCentredInTheLowerPartOfTheDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        let frame = noticeFrame(size: CGSize(width: 400, height: 64), in: visible)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.minY, visible.minY + visible.height * 0.14, accuracy: 0.5)
    }

    func testASecondDisplayKeepsItsOwnOrigin() {
        let external = CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        let frame = noticeFrame(size: CGSize(width: 400, height: 64), in: external)
        XCTAssertTrue(external.contains(frame))
        XCTAssertEqual(frame.midX, external.midX)
    }

    func testANoticeWiderThanTheDisplayIsClampedToIt() {
        let narrow = CGRect(x: 100, y: 0, width: 300, height: 400)
        let frame = noticeFrame(size: CGSize(width: 500, height: 64), in: narrow)
        XCTAssertTrue(narrow.contains(frame))
    }
}
