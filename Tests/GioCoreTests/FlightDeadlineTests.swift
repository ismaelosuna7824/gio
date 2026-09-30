import CoreGraphics
import XCTest
@testable import GioCore

/// The flight ends at Gio's own spring deadline, never on Core Animation
/// completion (which fired after 6-83 ms when layers were not yet rendered).
final class FlightDeadlineTests: XCTestCase {
    func testBeginSetsTheDeadlineAtNowPlusSettle() {
        var deadline = FlightDeadline()
        let armed = deadline.begin(now: 10, settle: 0.35)
        XCTAssertEqual(armed.deadline, 10.35, accuracy: 1e-9)
        XCTAssertTrue(deadline.isCurrent(armed.token))
        XCTAssertFalse(deadline.isDue(armed.token, now: 10.34))
        XCTAssertTrue(deadline.isDue(armed.token, now: 10.35))
    }

    func testRetargetExtendsTheDeadlineAndSupersedesTheOldToken() {
        var deadline = FlightDeadline()
        let first = deadline.begin(now: 10, settle: 0.35)
        let second = deadline.retarget(now: 10.2, settle: 0.35)
        XCTAssertEqual(second.deadline, 10.55, accuracy: 1e-9)
        XCTAssertFalse(deadline.isCurrent(first.token))
        XCTAssertTrue(deadline.isCurrent(second.token))
    }

    func testRetargetToAnEarlierLandingDoesNotShortenTheDeadline() {
        var deadline = FlightDeadline()
        _ = deadline.begin(now: 10, settle: 0.5)
        let second = deadline.retarget(now: 10.1, settle: 0.1)
        XCTAssertEqual(second.deadline, 10.5, accuracy: 1e-9)
    }

    func testAbortCancelsTheFlight() {
        var deadline = FlightDeadline()
        let armed = deadline.begin(now: 10, settle: 0.35)
        deadline.abort()
        XCTAssertFalse(deadline.isCurrent(armed.token))
        XCTAssertFalse(deadline.isDue(armed.token, now: 99))
        XCTAssertNil(deadline.deadline)
    }

    func testBeginAfterAbortStartsFresh() {
        var deadline = FlightDeadline()
        _ = deadline.begin(now: 10, settle: 5)
        deadline.abort()
        let armed = deadline.begin(now: 20, settle: 0.35)
        XCTAssertEqual(armed.deadline, 20.35, accuracy: 1e-9)
    }

    func testFinishClearsTheDeadlineOnce() {
        var deadline = FlightDeadline()
        let armed = deadline.begin(now: 10, settle: 0.35)
        XCTAssertTrue(deadline.finish(armed.token, now: 10.4))
        XCTAssertFalse(deadline.finish(armed.token, now: 10.5))
    }

    func testFinishBeforeTheDeadlineIsRefused() {
        var deadline = FlightDeadline()
        let armed = deadline.begin(now: 10, settle: 0.35)
        XCTAssertFalse(deadline.finish(armed.token, now: 10.01))
        XCTAssertTrue(deadline.isCurrent(armed.token))
    }

    func testSettleTimeOfTheDefaultSpringIsAboutAThirdOfASecond() {
        let settle = flightSettleTime(spring: .niri, travel: 800)
        XCTAssertGreaterThan(settle, 0.25)
        XCTAssertLessThan(settle, 0.5)
    }

    func testSettleTimeIsCappedAtTheSpringMaximum() {
        let soft = SpringParameters(dampingRatio: 3, stiffness: 100, epsilon: 0.0001)
        XCTAssertLessThanOrEqual(flightSettleTime(spring: soft, travel: 2000), SpringParameters.maxDuration)
    }

    func testTravelIsTheLargestEdgeMovement() {
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let to = CGRect(x: 250, y: -10, width: 420, height: 300)
        XCTAssertEqual(flightTravel(from: from, to: to), 250, accuracy: 1e-9)
    }

    func testTooShortFlightIsFlaggedOnlyWhenSomethingMoved() {
        XCTAssertTrue(flightTooShort(duration: 0.012, travel: 300))
        XCTAssertFalse(flightTooShort(duration: 0.012, travel: 0.5))
        XCTAssertFalse(flightTooShort(duration: 0.35, travel: 300))
        XCTAssertFalse(flightTooShort(duration: 0.05, travel: 300))
    }
}
