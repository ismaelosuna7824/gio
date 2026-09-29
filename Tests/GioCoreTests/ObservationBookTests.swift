import XCTest
@testable import GioCore

final class ObservationBookTests: XCTestCase {
    func testReconcileAttachesNewRunningPids() {
        var book = ObservationBook()
        let plan = book.reconcile(running: [10, 20])
        XCTAssertEqual(plan.attach, [10, 20])
        XCTAssertEqual(plan.detach, [])
    }

    func testReconcileIsIdleWhenNothingChanged() {
        var book = ObservationBook()
        book.didAttach(10)
        book.didAttach(20)
        let plan = book.reconcile(running: [10, 20])
        XCTAssertEqual(plan, ObservationPlan(attach: [], detach: []))
    }

    func testReconcileDetachesVanishedPids() {
        var book = ObservationBook()
        book.didAttach(10)
        book.didAttach(20)
        let plan = book.reconcile(running: [20, 30])
        XCTAssertEqual(plan.attach, [30])
        XCTAssertEqual(plan.detach, [10])
    }

    func testRefusedPidIsNotAutoRetriedByReconcile() {
        var book = ObservationBook()
        book.didRefuse(10)
        XCTAssertEqual(book.reconcile(running: [10]).attach, [])
    }

    func testRefusedPidIsRetriedOnActivation() {
        var book = ObservationBook()
        book.didRefuse(10)
        XCTAssertTrue(book.needsAttach(10))
    }

    func testObservedPidNeedsNoAttachOnActivation() {
        var book = ObservationBook()
        book.didAttach(10)
        XCTAssertFalse(book.needsAttach(10))
    }

    func testSuccessfulAttachClearsRefusal() {
        var book = ObservationBook()
        book.didRefuse(10)
        book.didAttach(10)
        XCTAssertTrue(book.refused.isEmpty)
        XCTAssertTrue(book.observed.contains(10))
    }

    func testRefusedPidThatQuitIsForgotten() {
        var book = ObservationBook()
        book.didRefuse(10)
        let plan = book.reconcile(running: [])
        XCTAssertEqual(plan.detach, [])
        XCTAssertTrue(book.refused.isEmpty)
    }

    func testDidDetachForgetsPid() {
        var book = ObservationBook()
        book.didAttach(10)
        book.didDetach(10)
        XCTAssertFalse(book.observed.contains(10))
        XCTAssertTrue(book.needsAttach(10))
    }

    func testRetryDelaysGrowThenStop() {
        let delays = (0..<ObservationRetry.maxRetries).compactMap {
            ObservationRetry.delay(afterFailedAttempt: $0)
        }
        XCTAssertEqual(delays.count, ObservationRetry.maxRetries)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertGreaterThan(delays.first ?? 0, 0)
        XCTAssertNil(ObservationRetry.delay(afterFailedAttempt: ObservationRetry.maxRetries))
    }
}
