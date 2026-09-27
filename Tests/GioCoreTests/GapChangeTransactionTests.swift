import XCTest
@testable import GioCore

final class GapChangeTransactionTests: XCTestCase {
    func testFailedSecondDisplayAndFailedRollbackReportsDivergence() {
        var calls: [String] = []
        let outcome = GapChangeTransaction.run(displays: ["A", "B"], newGap: 16, oldGap: 8) { id, gap in
            calls.append("\(id):\(gap)")
            return id == "A" && gap == 16
        }
        XCTAssertEqual(outcome, .divergent(rollbackFailures: ["A"]))
        XCTAssertEqual(calls, ["A:16", "B:16", "A:8"])
    }

    func testFailedSecondDisplayAndSuccessfulRollbackIsRecoverable() {
        var calls: [String] = []
        let outcome = GapChangeTransaction.run(displays: ["A", "B"], newGap: 16, oldGap: 8) { id, gap in
            calls.append("\(id):\(gap)")
            return id == "A"
        }
        XCTAssertEqual(outcome, .reverted)
        XCTAssertEqual(calls, ["A:16", "B:16", "A:8"])
    }

    func testSuccessfulChangeRequiresCallerToPersist() {
        let outcome = GapChangeTransaction.run(displays: ["A", "B"], newGap: 16, oldGap: 8) { _, _ in true }
        XCTAssertEqual(outcome, .applied)
    }
}
