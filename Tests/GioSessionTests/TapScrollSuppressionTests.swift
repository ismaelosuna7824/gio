import Foundation
import XCTest
@testable import GioSession

/// TG-10: the scroll-suppression tap (its own thread) asks whether to
/// swallow a scroll event; the session queue sets the armed deadline (system
/// uptime). The answer is one lock and a comparison. TG-12: `suppress`
/// reports when armed flips, so the host enables or disables the scroll tap
/// only then (not on every drain while the fingers move).
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

    func testSuppressReportsOnlyArmedTransitions() {
        let suppression = TapScrollSuppression()
        XCTAssertFalse(suppression.suppress(until: nil), "already off")
        XCTAssertTrue(suppression.suppress(until: 3), "armed: enable the scroll tap")
        XCTAssertFalse(suppression.suppress(until: 4), "renewed: nothing to toggle")
        XCTAssertTrue(suppression.suppress(until: nil), "disarmed: disable it")
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
