import XCTest
@testable import GioCore

/// TG-10: a quick three-finger tap arms tap-to-swipe; expiry, a second tap
/// or a mouse button disarm it. TG-12: while armed a horizontal two-finger
/// stroke scrolls the strip like the TG-03 scroll (began, changed, ended with
/// the release velocity, cancelled by an extra finger), a vertical one is one
/// workspace step at `stepDistance`; the fingers lift before the next stroke.
final class TapToSwipeTests: XCTestCase {
    /// `count` fingers spread 0.1 apart around (x, y).
    private func frame(_ t: TimeInterval, fingers count: Int, x: Double = 0.5, y: Double = 0.5) -> TouchFrame {
        TouchFrame(timestamp: t, contacts: (0..<count).map {
            TouchContact(id: Int32($0), x: x + Double($0) * 0.1 - Double(count - 1) * 0.05, y: y)
        })
    }

    private func feed(_ machine: inout TapToSwipe, _ frames: [TouchFrame]) -> [TapToSwipeEvent] {
        frames.flatMap { machine.feed($0) }
    }

    /// Event kinds without the floating-point payloads.
    private func kinds(_ events: [TapToSwipeEvent]) -> [String] {
        events.map {
            switch $0 {
            case .armed: return "armed"
            case .scrollBegan: return "began"
            case .scrollChanged: return "changed"
            case .scrollEnded: return "ended"
            case .scrollCancelled: return "cancelled"
            case .step(let direction): return "step-\(direction.rawValue)"
            case .disarmed(let reason): return "disarmed-\(reason.rawValue)"
            }
        }
    }

    /// Three fingers down at `t` for 0.1 s without moving, then lifted.
    private func tap(at t: TimeInterval) -> [TouchFrame] {
        [frame(t, fingers: 3), frame(t + 0.05, fingers: 3, x: 0.505), frame(t + 0.1, fingers: 3), frame(t + 0.11, fingers: 0)]
    }

    /// TG-14: three still fingers from `t - duration`, a frame every 0.25 s,
    /// reaching the hold at `t`, resting 0.1 s more, lifted at `t + 0.11`.
    private func hold(endingAt t: TimeInterval, duration: TimeInterval = TapToSwipe.defaultHoldDuration) -> [TouchFrame] {
        let start = t - duration
        let steps = Int((duration / 0.25).rounded())
        return (0...steps).map { frame(start + Double($0) * 0.25, fingers: 3) }
            + [frame(t + 0.05, fingers: 3, x: 0.505), frame(t + 0.1, fingers: 3), frame(t + 0.11, fingers: 0)]
    }

    /// Two fingers from the middle by (dx, dy) in four frames 10 ms apart, then lifted.
    private func stroke(at t: TimeInterval, dx: Double, dy: Double, lift: Bool = true) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        for step in 0...4 {
            let progress = Double(step) / 4
            frames.append(frame(t + Double(step) * 0.01, fingers: 2, x: 0.5 + dx * progress, y: 0.5 + dy * progress))
        }
        if lift {
            frames.append(frame(t + 0.05, fingers: 0))
        }
        return frames
    }

    private func armed(stepDistance: Double = TapToSwipe.defaultStepDistance) -> TapToSwipe {
        var machine = TapToSwipe(stepDistance: stepDistance)
        _ = feed(&machine, hold(endingAt: 0))
        return machine
    }

    // MARK: Arming (TG-14: a three-finger hold)

    func testAStillThreeFingerHoldArmsAtTheHoldTimeWithTheFingersDown() throws {
        XCTAssertEqual(TapToSwipe.defaultHoldDuration, 2.0)
        var machine = TapToSwipe()
        XCTAssertEqual(feed(&machine, [frame(0, fingers: 3), frame(1, fingers: 3), frame(1.99, fingers: 3, x: 0.51)]), [],
                       "not before the hold time")
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, [frame(2.0, fingers: 3)]), [.armed], "at the hold time, fingers still down")
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 2.0 + TapToSwipe.armedWindow, accuracy: 1e-9)
        XCTAssertEqual(feed(&machine, [frame(3, fingers: 3), frame(3.5, fingers: 0)]), [], "the long touch lifting is no tap")
        XCTAssertTrue(machine.isArmed)
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 3.5 + TapToSwipe.armedWindow, accuracy: 1e-9, "renewed until the lift")
    }

    func testTheHoldTimeIsConfigurable() {
        var machine = TapToSwipe(holdDuration: 0.5)
        XCTAssertEqual(feed(&machine, [frame(0, fingers: 3), frame(0.45, fingers: 3)]), [])
        XCTAssertEqual(feed(&machine, [frame(0.5, fingers: 3)]), [.armed])
        var later = TapToSwipe()
        later.holdDuration = 3
        XCTAssertEqual(feed(&later, [frame(0, fingers: 3), frame(2.5, fingers: 3)]), [])
        XCTAssertEqual(feed(&later, [frame(3, fingers: 3)]), [.armed])
    }

    func testAQuickTapNoLongerArms() {
        var machine = TapToSwipe()
        XCTAssertEqual(feed(&machine, tap(at: 0)), [])
        XCTAssertFalse(machine.isArmed)
    }

    func testLiftingBeforeTheHoldTimeCancelsSilently() {
        var machine = TapToSwipe()
        XCTAssertEqual(feed(&machine, [frame(0, fingers: 3), frame(1.5, fingers: 3), frame(1.6, fingers: 2), frame(2.1, fingers: 3)]), [],
                       "a finger lifted and put back starts over")
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, [frame(4.1, fingers: 3)]), [.armed], "from the new touch-down")
    }

    func testMovingFingersCancelTheHold() {
        var machine = TapToSwipe()
        let drag = (0...20).map { frame(Double($0) * 0.1, fingers: 3, x: 0.5 + Double($0) * 0.01) }
        XCTAssertEqual(feed(&machine, drag), [], "a three-finger drag never arms")
        XCTAssertGreaterThan(0.05, TapToSwipe.maxHoldTravel)
    }

    func testAFourthFingerCancelsTheHold() {
        var machine = TapToSwipe()
        let four = [frame(0, fingers: 3), frame(1, fingers: 4), frame(2.5, fingers: 3), frame(3, fingers: 3)]
        XCTAssertEqual(feed(&machine, four), [], "exactly three contacts the whole time")
        XCTAssertFalse(machine.isArmed)
    }

    func testRestingFingersMayDriftALittle() {
        var machine = TapToSwipe()
        let drift = (0...8).map { frame(Double($0) * 0.25, fingers: 3, x: 0.5 + Double($0) * 0.003) }
        XCTAssertEqual(feed(&machine, drift), [.armed], "0.024 of drift is still a hold")
    }

    func testTwoFingerFramesBeforeArmingAreIgnored() {
        var machine = TapToSwipe()
        XCTAssertEqual(feed(&machine, stroke(at: 0, dx: -0.3, dy: 0)), [])
        XCTAssertEqual(feed(&machine, stroke(at: 1, dx: 0, dy: 0.3)), [])
        XCTAssertFalse(machine.isArmed)
    }

    // MARK: Horizontal strokes scroll (TG-12)

    func testAnArmedHorizontalStrokeScrollsWithTheFingers() throws {
        var machine = armed()
        let events = feed(&machine, stroke(at: 0.5, dx: -0.3, dy: 0))
        XCTAssertEqual(kinds(events), ["began", "changed", "changed", "changed", "changed", "ended"])
        let travel = events.reduce(0.0) { sum, event in
            if case .scrollChanged(let dx) = event {
                return sum + dx
            }
            return sum
        }
        XCTAssertEqual(travel, -0.3, accuracy: 1e-9, "the strip gets every bit of the fingers' travel")
        guard case .scrollEnded(let velocity) = try XCTUnwrap(events.last) else {
            return XCTFail("ends with the release velocity")
        }
        XCTAssertEqual(velocity, -6, accuracy: 1e-6, "0.3 in 50 ms")
        XCTAssertTrue(machine.isArmed)
    }

    func testAScrollCommitsAtTheSmallCommitDistanceNotTheStepDistance() {
        var machine = armed()
        let begin = GestureRecognizerSettings.defaultCommitDistance
        XCTAssertEqual(feed(&machine, [frame(0.5, fingers: 2), frame(0.51, fingers: 2, x: 0.5 - begin / 2)]), [])
        XCTAssertEqual(kinds(feed(&machine, [frame(0.52, fingers: 2, x: 0.5 - begin - 0.001)])), ["began", "changed"])
    }

    func testRestingFingersEndAScrollWithoutVelocity() throws {
        var machine = armed()
        let frames = stroke(at: 0.5, dx: -0.2, dy: 0, lift: false) + [frame(0.7, fingers: 2, x: 0.3), frame(0.71, fingers: 0)]
        let events = feed(&machine, frames)
        guard case .scrollEnded(let velocity) = try XCTUnwrap(events.last) else {
            return XCTFail("a lift ends the scroll")
        }
        XCTAssertEqual(velocity, 0, accuracy: 1e-9)
    }

    func testAnExtraFingerCancelsTheScrollUntilTheLift() {
        var machine = armed()
        let frames = stroke(at: 0.5, dx: -0.2, dy: 0, lift: false)
            + [frame(0.6, fingers: 3, x: 0.3), frame(0.61, fingers: 2, x: 0.1), frame(0.62, fingers: 2, x: 0.0)]
        XCTAssertEqual(kinds(feed(&machine, frames)).suffix(1), ["cancelled"], "no new scroll from the same touch")
        XCTAssertEqual(kinds(feed(&machine, [frame(0.7, fingers: 0)] + stroke(at: 0.8, dx: 0.2, dy: 0))).first, "began")
    }

    func testDisarmingMidScrollCancelsItFirst() {
        var machine = armed()
        _ = feed(&machine, stroke(at: 0.5, dx: -0.2, dy: 0, lift: false))
        XCTAssertEqual(machine.disarm(.mouse), [.scrollCancelled, .disarmed(.mouse)])
        var other = armed()
        _ = feed(&other, stroke(at: 0.5, dx: -0.2, dy: 0, lift: false))
        XCTAssertEqual(other.expire(), [.scrollCancelled, .disarmed(.expired)])
    }

    // MARK: Vertical strokes step

    func testAnArmedVerticalStrokeStepsOnceAtTheStepDistance() {
        XCTAssertEqual(TapToSwipe.defaultStepDistance, 0.1, "TG-12: back to 0.1 for the vertical step")
        var machine = armed()
        let short = stroke(at: 0.5, dx: 0, dy: TapToSwipe.defaultStepDistance - 0.02)
        XCTAssertEqual(feed(&machine, short), [], "short of the step distance")
        XCTAssertEqual(feed(&machine, stroke(at: 1, dx: 0, dy: 0.3)), [.step(.up)], "one step per stroke")
        XCTAssertEqual(feed(&machine, stroke(at: 1.5, dx: 0, dy: -0.3)), [.step(.down)])
        XCTAssertTrue(machine.isArmed)
    }

    func testTheStepDistanceIsConfigurable() {
        XCTAssertEqual(TapToSwipe().stepDistance, TapToSwipe.defaultStepDistance)
        var machine = armed(stepDistance: 0.35)
        XCTAssertEqual(feed(&machine, stroke(at: 0.5, dx: 0, dy: 0.3)), [], "under the configured distance")
        XCTAssertEqual(feed(&machine, stroke(at: 1, dx: 0, dy: 0.4)), [.step(.up)], "over it: one step")
        machine.stepDistance = 0.2
        XCTAssertEqual(feed(&machine, stroke(at: 1.5, dx: 0, dy: -0.25)), [.step(.down)], "a new distance applies to the next stroke")
    }

    func testTheFingersMustLiftBeforeTheNextStep() {
        var machine = armed()
        let long = (0...12).map { frame(0.5 + Double($0) * 0.01, fingers: 2, y: 0.5 + Double($0) * 0.03) }
        XCTAssertEqual(feed(&machine, long), [.step(.up)], "a long stroke is still one step")
        XCTAssertEqual(feed(&machine, [frame(0.7, fingers: 1)]), [])
        XCTAssertEqual(feed(&machine, stroke(at: 0.8, dx: 0, dy: 0.3)), [.step(.up)], "lifted: the next stroke steps")
    }

    func testADiagonalStrokeIsIgnoredUntilTheLift() {
        var machine = armed()
        XCTAssertEqual(feed(&machine, stroke(at: 0.5, dx: 0.3, dy: 0.4, lift: false)), [], "not twice as vertical as horizontal")
        XCTAssertEqual(feed(&machine, [frame(0.6, fingers: 2, x: 0.8, y: 0.95)]), [], "consumed until the fingers lift")
        XCTAssertEqual(feed(&machine, [frame(0.7, fingers: 0)] + stroke(at: 0.8, dx: 0, dy: -0.3)), [.step(.down)])
    }

    func testAVerticalStrokeTurningDiagonalIsConsumed() {
        var machine = armed(stepDistance: 0.3)
        let frames = [frame(0.5, fingers: 2), frame(0.51, fingers: 2, y: 0.6), frame(0.52, fingers: 2, x: 0.3, y: 0.7),
                      frame(0.53, fingers: 2, x: 0.3, y: 0.9)]
        XCTAssertEqual(feed(&machine, frames), [])
    }

    func testStrokesWithOtherFingerCountsAreIgnored() {
        var machine = armed()
        let three = (0...4).map { frame(0.5 + Double($0) * 0.01, fingers: 3, x: 0.5 - Double($0) * 0.08) } + [frame(0.6, fingers: 0)]
        XCTAssertEqual(feed(&machine, three), [])
        let four = (0...4).map { frame(0.7 + Double($0) * 0.01, fingers: 4, y: 0.5 + Double($0) * 0.08) } + [frame(0.8, fingers: 0)]
        XCTAssertEqual(feed(&machine, four), [])
        XCTAssertTrue(machine.isArmed)
    }

    func testTheArmingHoldsLiftingFingersAreNotAStroke() {
        var machine = TapToSwipe()
        let frames = [frame(0, fingers: 3), frame(2, fingers: 3), frame(2.08, fingers: 2)]
            + (1...6).map { frame(2.08 + Double($0) * 0.01, fingers: 2, x: 0.5 - Double($0) * 0.05) }
        XCTAssertEqual(feed(&machine, frames), [.armed], "the hold's own fingers lift before a stroke counts")
    }

    // MARK: Window

    func testFingersOnTheTrackpadRenewTheWindow() throws {
        var machine = armed()
        _ = feed(&machine, stroke(at: 2, dx: -0.3, dy: 0))
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 2.05 + TapToSwipe.armedWindow, accuracy: 1e-9, "from the stroke's lift")
        XCTAssertEqual(feed(&machine, stroke(at: 4, dx: 0, dy: 0.3)), [.step(.up)], "renewed: still armed after 4 s")
        // A long scroll keeps it alive while the fingers move.
        let long = (0...40).map { frame(5 + Double($0) * 0.1, fingers: 2, x: 0.9 - Double($0) * 0.02) }
        XCTAssertFalse(kinds(feed(&machine, long)).contains { $0.hasPrefix("disarmed") })
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 9 + TapToSwipe.armedWindow, accuracy: 1e-9)
    }

    func testAFrameAfterTheWindowDisarmsFirst() {
        var machine = armed()
        let late = 0.11 + TapToSwipe.armedWindow + 0.5
        XCTAssertEqual(feed(&machine, stroke(at: late, dx: -0.3, dy: 0)), [.disarmed(.expired)])
        XCTAssertFalse(machine.isArmed)
        XCTAssertNil(machine.armedUntil)
    }

    func testExpireDisarmsOnlyWhenArmed() {
        var idle = TapToSwipe()
        XCTAssertEqual(idle.expire(), [])
        var machine = armed()
        XCTAssertEqual(machine.expire(), [.disarmed(.expired)])
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, stroke(at: 1, dx: -0.3, dy: 0)), [], "disarmed: two fingers scroll again")
    }

    func testASecondTapDisarms() {
        var machine = armed()
        XCTAssertEqual(feed(&machine, tap(at: 1)), [.disarmed(.tap)], "a quick tap still disarms")
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, tap(at: 2)), [], "and a quick tap never arms")
        XCTAssertEqual(feed(&machine, hold(endingAt: 5)), [.armed], "a hold arms again")
    }

    func testAHoldWhileArmedDoesNotDisarm() {
        var machine = armed()
        XCTAssertEqual(feed(&machine, hold(endingAt: 3)), [])
        XCTAssertTrue(machine.isArmed)
    }

    func testAMouseButtonDisarms() {
        var machine = armed()
        XCTAssertEqual(machine.disarm(.mouse), [.disarmed(.mouse)])
        XCTAssertEqual(machine.disarm(.mouse), [], "already off")
    }
}
