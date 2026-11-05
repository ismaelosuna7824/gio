import Foundation
import XCTest
@testable import GioSession

/// TG-10: the hotkey tap (its own thread) asks whether to swallow a scroll
/// event; the session queue sets the armed deadline (system uptime). The
/// answer is one lock and a comparison.
final class TapScrollSuppressionTests: XCTestCase {
    func testSwallowsOnlyUntilTheDeadline() {
        let suppression = TapScrollSuppression()
        XCTAssertFalse(suppression.isArmed)
        XCTAssertFalse(suppression.swallows(at: 0), "nothing armed")
        suppression.suppress(until: 10)
        XCTAssertTrue(suppression.isArmed)
        XCTAssertTrue(suppression.swallows(at: 5))
        XCTAssertTrue(suppression.swallows(at: 10))
        XCTAssertFalse(suppression.swallows(at: 10.01), "expired")
        suppression.suppress(until: nil)
        XCTAssertFalse(suppression.isArmed)
        XCTAssertFalse(suppression.swallows(at: 5))
    }

    func testTheSubscriptionFlagIsIndependentOfTheDeadline() {
        let suppression = TapScrollSuppression()
        XCTAssertFalse(suppression.isEnabled)
        suppression.isEnabled = true
        XCTAssertTrue(suppression.isEnabled)
        XCTAssertFalse(suppression.swallows(at: 0))
    }

    func testConcurrentReadersAndAWriterDoNotRace() {
        let suppression = TapScrollSuppression()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for step in 0..<200 {
                if index == 0 {
                    suppression.suppress(until: step.isMultiple(of: 2) ? Double(step) : nil)
                } else {
                    _ = suppression.swallows(at: Double(step))
                }
            }
        }
        suppression.suppress(until: 1)
        XCTAssertTrue(suppression.swallows(at: 0.5))
    }
}
