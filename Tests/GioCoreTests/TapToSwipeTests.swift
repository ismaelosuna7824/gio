import XCTest
@testable import GioCore

/// TG-10: a quick three-finger tap arms tap-to-swipe; while armed, each
/// two-finger stroke is one step (window left/right, workspace up/down) and
/// the fingers must lift before the next one. Expiry, a second tap or a
/// mouse button disarm it.
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

    /// Three fingers down at `t` for 0.1 s without moving, then lifted.
    private func tap(at t: TimeInterval) -> [TouchFrame] {
        [frame(t, fingers: 3), frame(t + 0.05, fingers: 3, x: 0.505), frame(t + 0.1, fingers: 3), frame(t + 0.11, fingers: 0)]
    }

    /// Two fingers from (x, y) by (dx, dy) in four frames 10 ms apart, then lifted.
    private func stroke(at t: TimeInterval, dx: Double, dy: Double, lift: Bool = true) -> [TouchFrame] {
        var frames = (0...4).map { frame(t + Double($0) * 0.01, fingers: 2, x: 0.5 + dx * Double($0) / 4, y: 0.5 + dy * Double($0) / 4) }
        if lift {
            frames.append(frame(t + 0.05, fingers: 0))
        }
        return frames
    }

    private func armed() -> TapToSwipe {
        var machine = TapToSwipe()
        _ = feed(&machine, tap(at: 0))
        return machine
    }

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
        XCTAssertFalse(machine.isArmed)
    }

    func testAnArmedStrokeStepsOnceAtTheStepDistance() {
        var machine = armed()
        let short = stroke(at: 0.5, dx: -(TapToSwipe.stepDistance - 0.01), dy: 0)
        XCTAssertEqual(feed(&machine, short), [], "short of the step distance")
        XCTAssertEqual(feed(&machine, stroke(at: 1, dx: -0.3, dy: 0)), [.step(.left)], "one step per stroke")
        XCTAssertEqual(feed(&machine, stroke(at: 1.5, dx: 0.3, dy: 0)), [.step(.right)])
        XCTAssertEqual(feed(&machine, stroke(at: 2, dx: 0, dy: 0.3)), [.step(.up)])
        XCTAssertEqual(feed(&machine, stroke(at: 2.5, dx: 0, dy: -0.3)), [.step(.down)])
        XCTAssertTrue(machine.isArmed)
    }

    func testTheFingersMustLiftBeforeTheNextStep() {
        var machine = armed()
        let long = (0...12).map { frame(0.5 + Double($0) * 0.01, fingers: 2, x: 0.5 - Double($0) * 0.04) }
        XCTAssertEqual(feed(&machine, long), [.step(.left)], "a long stroke is still one step")
        XCTAssertEqual(feed(&machine, [frame(0.7, fingers: 1)]), [])
        XCTAssertEqual(feed(&machine, stroke(at: 0.8, dx: -0.3, dy: 0)), [.step(.left)], "lifted: the next stroke steps")
    }

    func testADiagonalStrokeIsIgnoredUntilTheLift() {
        var machine = armed()
        XCTAssertEqual(feed(&machine, stroke(at: 0.5, dx: -0.2, dy: 0.15, lift: false)), [], "not twice as horizontal as vertical")
        XCTAssertEqual(feed(&machine, [frame(0.6, fingers: 2, x: 0.1, y: 0.65)]), [], "consumed until the fingers lift")
        XCTAssertEqual(feed(&machine, [frame(0.7, fingers: 0)] + stroke(at: 0.8, dx: 0, dy: -0.3)), [.step(.down)])
    }

    func testStrokesWithOtherFingerCountsAreIgnored() {
        var machine = armed()
        let three = (0...4).map { frame(0.5 + Double($0) * 0.01, fingers: 3, x: 0.5 - Double($0) * 0.08) } + [frame(0.6, fingers: 0)]
        XCTAssertEqual(feed(&machine, three), [])
        let four = (0...4).map { frame(0.7 + Double($0) * 0.01, fingers: 4, x: 0.5 - Double($0) * 0.08) } + [frame(0.8, fingers: 0)]
        XCTAssertEqual(feed(&machine, four), [])
        XCTAssertTrue(machine.isArmed)
    }

    func testAThirdFingerLandingMidStrokeEndsTheStroke() {
        var machine = armed()
        let frames = stroke(at: 0.5, dx: -0.05, dy: 0, lift: false)
            + (0...4).map { frame(0.6 + Double($0) * 0.01, fingers: 3, x: 0.45 - Double($0) * 0.08) }
            + [frame(0.7, fingers: 2, x: 0.1)]
        XCTAssertEqual(feed(&machine, frames), [], "the two fingers left are still the old touch")
    }

    func testTheArmingTapsLiftingFingersAreNotAStroke() {
        var machine = TapToSwipe()
        let frames = [frame(0, fingers: 3), frame(0.05, fingers: 3), frame(0.08, fingers: 2)]
            + (1...6).map { frame(0.08 + Double($0) * 0.01, fingers: 2, x: 0.5 - Double($0) * 0.05) }
        XCTAssertEqual(feed(&machine, frames), [.armed], "the tap's own fingers lift before a stroke counts")
    }

    func testFingersOnTheTrackpadRenewTheWindow() throws {
        var machine = armed()
        _ = feed(&machine, stroke(at: 2, dx: -0.3, dy: 0))
        XCTAssertEqual(try XCTUnwrap(machine.armedUntil), 2.05 + TapToSwipe.armedWindow, accuracy: 1e-9, "from the stroke's lift")
        XCTAssertEqual(feed(&machine, stroke(at: 4, dx: 0.3, dy: 0)), [.step(.right)], "renewed: still armed after 4 s")
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

    /// Natural: the content follows the fingers, so swiping left shows the
    /// window on the right; vertical steps use the workspace swipe's mapping.
    func testStepActionsFollowTheNaturalDirection() {
        XCTAssertEqual(tapSwipeAction(.left, natural: true), .focusRight)
        XCTAssertEqual(tapSwipeAction(.right, natural: true), .focusLeft)
        XCTAssertEqual(tapSwipeAction(.left, natural: false), .focusLeft)
        XCTAssertEqual(tapSwipeAction(.right, natural: false), .focusRight)
        XCTAssertEqual(tapSwipeAction(.up, natural: true), workspaceSwipeAction(.up, natural: true))
        XCTAssertEqual(tapSwipeAction(.down, natural: true), .focusWorkspaceUp)
        XCTAssertEqual(tapSwipeAction(.up, natural: false), .focusWorkspaceUp)
    }
}
