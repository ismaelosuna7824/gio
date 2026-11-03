import CoreGraphics
import XCTest
@testable import GioCore

/// The frame shape shared by the float diagnostics and the CLI.
final class LogFrameTests: XCTestCase {
    func testLogsWholePoints() {
        XCTAssertEqual(logFrame(CGRect(x: 0, y: 16, width: 744, height: 933)), "(0,16,744,933)")
    }

    func testTruncatesTheFractionalPartLikeTheCli() {
        XCTAssertEqual(logFrame(CGRect(x: 759.6, y: 8.2, width: 744.5, height: 933.9)), "(759,8,744,933)")
    }

    func testNegativeOriginsStayReadable() {
        XCTAssertEqual(logFrame(CGRect(x: -1499, y: -30, width: 744, height: 933)), "(-1499,-30,744,933)")
    }
}
