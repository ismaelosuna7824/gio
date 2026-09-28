import CoreGraphics
import XCTest
@testable import GioMacOS

/// The live y=8→y=39 clamp came from mixing these two spaces. Main display
/// 1800×1169, menu bar 39pt: Cocoa y=8 with h=1114 must become AX y=47.
final class AXCoordinateFlipTests: XCTestCase {
    private let flip = AXVerticalFlip(displayHeight: 1169)

    func testCocoaToAX() {
        XCTAssertEqual(
            flip.toAX(CGRect(x: 8, y: 8, width: 900, height: 1114)),
            CGRect(x: 8, y: 47, width: 900, height: 1114)
        )
    }

    func testAXToCocoa() {
        XCTAssertEqual(
            flip.toCocoa(CGRect(x: 8, y: 39, width: 900, height: 1114)),
            CGRect(x: 8, y: 16, width: 900, height: 1114)
        )
    }

    func testRoundTrip() {
        let cocoa = CGRect(x: 316, y: 58, width: 400, height: 700)
        XCTAssertEqual(flip.toCocoa(flip.toAX(cocoa)), cocoa)
        let ax = CGRect(x: 100, y: 200, width: 300, height: 400)
        XCTAssertEqual(flip.toAX(flip.toCocoa(ax)), ax)
    }

    func testSizesSurviveUntouched() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        XCTAssertEqual(flip.toAX(frame).size, frame.size)
        XCTAssertEqual(flip.toCocoa(frame).size, frame.size)
    }
}
