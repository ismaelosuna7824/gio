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
        _ = feed(&machine, tap(at: 0))
        return machine
    }

    // MARK: Arming

    func testAQuickStillThreeFingerTapArms() throws {
        var machine = TapToSwipe()
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, tap(at: 0)), [.armed])
        XCTAssertTrue(machine.isArmed)
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 0.11 + TapToSwipe.armedWindow, accuracy: 1e-9, "from the lift")
    }

    func testTheLiftFrameMayStillHaveFingersDown() {
        var machine = TapToSwipe()
        // The gate delivers the frame that drops below three, often two fingers.
        let frames = [frame(0, fingers: 3), frame(0.05, fingers: 3), frame(0.08, fingers: 2)]
        XCTAssertEqual(feed(&machine, frames), [.armed])
    }

    func testAThreeFingerDragIsNotATap() {
        var machine = TapToSwipe()
        let drag = (0...5).map { frame(Double($0) * 0.02, fingers: 3, x: 0.5 + Double($0) * 0.01) } + [frame(0.12, fingers: 0)]
        XCTAssertEqual(feed(&machine, drag), [], "0.05 of travel is a drag, not a tap")
        XCTAssertFalse(machine.isArmed)
    }

    func testATapThatRestsTooLongIsNotATap() {
        var machine = TapToSwipe()
        let slow = [frame(0, fingers: 3), frame(0.2, fingers: 3), frame(TapToSwipe.maxTapDuration + 0.05, fingers: 0)]
        XCTAssertEqual(feed(&machine, slow), [])
        XCTAssertFalse(machine.isArmed)
    }

    func testAFourthFingerSpoilsTheTap() {
        var machine = TapToSwipe()
        let four = [frame(0, fingers: 3), frame(0.03, fingers: 4), frame(0.06, fingers: 3), frame(0.1, fingers: 0)]
        XCTAssertEqual(feed(&machine, four), [], "exactly three contacts at the peak")
        XCTAssertEqual(feed(&machine, tap(at: 1)), [.armed], "the next clean tap still arms")
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

    func testTheArmingTapsLiftingFingersAreNotAStroke() {
        var machine = TapToSwipe()
        let frames = [frame(0, fingers: 3), frame(0.05, fingers: 3), frame(0.08, fingers: 2)]
            + (1...6).map { frame(0.08 + Double($0) * 0.01, fingers: 2, x: 0.5 - Double($0) * 0.05) }
        XCTAssertEqual(feed(&machine, frames), [.armed], "the tap's own fingers lift before a stroke counts")
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
        XCTAssertEqual(feed(&machine, tap(at: 1)), [.disarmed(.tap)])
        XCTAssertFalse(machine.isArmed)
        XCTAssertEqual(feed(&machine, tap(at: 2)), [.armed], "and a third arms again")
    }

    func testAMouseButtonDisarms() {
        var machine = armed()
        XCTAssertEqual(machine.disarm(.mouse), [.disarmed(.mouse)])
        XCTAssertEqual(machine.disarm(.mouse), [], "already off")
    }
}
