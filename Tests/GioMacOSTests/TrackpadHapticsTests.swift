import AppKit
import GioCore
import XCTest
@testable import GioMacOS

/// TG-14: the trackpad clicks when a hold arms tap-to-swipe (a firm level
/// change) and a lighter click when a tap turns it off.
final class TrackpadHapticsTests: XCTestCase {
    func testEachFeedbackMapsToItsPattern() {
        XCTAssertEqual(hapticPattern(for: .levelChange), .levelChange)
        XCTAssertEqual(hapticPattern(for: .alignment), .alignment)
    }
}
