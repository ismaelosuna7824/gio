import XCTest
@testable import GioCore

/// NF-04: analytical spring (under, critically and over damped), completion
/// by epsilon or the hard cap, and velocity-preserving retargets.
final class SpringTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func params(_ ratio: Double, stiffness: Double = 800) -> SpringParameters {
        SpringParameters(dampingRatio: ratio, stiffness: stiffness, epsilon: 0.0001)
    }

    // MARK: - Math

    func testNiriDefaults() {
        XCTAssertEqual(SpringParameters.niri.dampingRatio, 1.0)
        XCTAssertEqual(SpringParameters.niri.stiffness, 800)
        XCTAssertEqual(SpringParameters.niri.epsilon, 0.0001)
    }

    func testStartsAtTheGivenDisplacementAndVelocityInEveryRegime() {
        for ratio in [0.5, 1.0, 2.0] {
            let start = params(ratio).state(displacement: 100, velocity: -300, at: 0)
            XCTAssertEqual(start.displacement, 100, accuracy: 1e-9, "ratio \(ratio)")
            XCTAssertEqual(start.velocity, -300, accuracy: 1e-9, "ratio \(ratio)")
        }
    }

    func testMatchesNumericIntegrationInEveryRegime() {
        for ratio in [0.5, 1.0, 2.0] {
            let spring = params(ratio)
            var x = 100.0, v = -300.0
            let omega2 = spring.stiffness, damping = 2 * ratio * spring.stiffness.squareRoot()
            let dt = 1e-5
            var t = 0.0
            while t < 0.25 {
                v += (-omega2 * x - damping * v) * dt
                x += v * dt
                t += dt
            }
            let exact = spring.state(displacement: 100, velocity: -300, at: t)
            XCTAssertEqual(exact.displacement, x, accuracy: 0.05, "ratio \(ratio)")
            XCTAssertEqual(exact.velocity, v, accuracy: 1.0, "ratio \(ratio)")
        }
    }

    func testEveryRegimeConvergesToRest() {
        for ratio in [0.3, 0.5, 1.0, 2.0, 3.0] {
            let end = params(ratio).state(displacement: 400, velocity: 0, at: 4)
            XCTAssertEqual(end.displacement, 0, accuracy: 0.01, "ratio \(ratio)")
            XCTAssertEqual(end.velocity, 0, accuracy: 0.01, "ratio \(ratio)")
        }
    }

    func testCriticallyDampedNeverOvershoots() {
        let spring = params(1.0)
        var previous = 400.0
        for step in 1...400 {
            let d = spring.state(displacement: 400, velocity: 0, at: Double(step) * 0.005).displacement
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, previous + 1e-9)
            previous = d
        }
    }

    func testUnderDampedOvershootsAndOverDampedDoesNot() {
        var overshoot = false
        for step in 1...200 where params(0.3).state(displacement: 400, velocity: 0, at: Double(step) * 0.005).displacement < -1 {
            overshoot = true
        }
        XCTAssertTrue(overshoot)
        for step in 1...400 {
            XCTAssertGreaterThanOrEqual(
                params(2.5).state(displacement: 400, velocity: 0, at: Double(step) * 0.005).displacement, 0
            )
        }
    }

    // MARK: - Animation

    private func slide(
        _ window: WindowID, from: CGFloat = 0, to: CGFloat = 800, spring: SpringParameters = .niri
    ) -> WindowAnimation {
        WindowAnimation(
            id: window, from: CGRect(x: from, y: 0, width: 300, height: 400),
            to: CGRect(x: to, y: 0, width: 300, height: 400), spring: spring
        )
    }

    func testSpringAnimationStartsAtFromAndPinsToTargetAtCompletion() {
        let animation = slide(id(1))
        XCTAssertEqual(animation.frame(at: 0).origin.x, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(animation.duration, 0.1)
        XCTAssertLessThanOrEqual(animation.duration, SpringParameters.maxDuration)
        XCTAssertEqual(animation.frame(at: animation.duration).origin.x, 800)
        XCTAssertEqual(animation.frame(at: animation.duration + 5).origin.x, 800)
        XCTAssertFalse(animation.isComplete(at: animation.duration - 0.01))
        XCTAssertTrue(animation.isComplete(at: animation.duration))
        XCTAssertEqual(animation.velocity(at: animation.duration + 1), .zero)
    }

    func testCriticalSpringIsFasterThanTheEaseOutItReplaces() {
        XCTAssertLessThan(slide(id(1)).duration, 0.5)
    }

    func testHardCapBoundsAVerySoftSpring() {
        let soft = slide(id(1), spring: SpringParameters(dampingRatio: 0.2, stiffness: 100, epsilon: 0.0001))
        XCTAssertEqual(soft.duration, SpringParameters.maxDuration, accuracy: 1e-9)
        XCTAssertEqual(soft.frame(at: soft.duration).origin.x, 800)
    }

    func testMotionFrameKeepsPositionOnlySizeTiming() {
        let animation = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 300, height: 400),
            to: CGRect(x: 500, y: 0, width: 200, height: 500), spring: .niri
        )
        let middle = animation.motionFrame(at: 0.05)
        XCTAssertEqual(middle.size.width, 200)
        XCTAssertEqual(middle.size.height, 400)
        XCTAssertGreaterThan(middle.origin.x, 0)
        XCTAssertLessThan(middle.origin.x, 500)
    }

    func testEaseOutAnimationsAreUntouched() {
        let animation = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 50, height: 50),
            to: CGRect(x: 100, y: 0, width: 50, height: 50), duration: 1, easing: .linear
        )
        XCTAssertNil(animation.spring)
        XCTAssertEqual(animation.frame(at: 0.5).origin.x, 50, accuracy: 1e-9)
        XCTAssertEqual(animation.velocity(at: 0.5), .zero)
    }

    func testSpringingConvertsAnExistingPlanKeepingItsEndpoints() {
        let plain = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 50, height: 50),
            to: CGRect(x: 100, y: 0, width: 50, height: 50), duration: 0.2, easing: .easeOut
        )
        let sprung = plain.springing(.niri)
        XCTAssertEqual(sprung.from, plain.from)
        XCTAssertEqual(sprung.to, plain.to)
        XCTAssertEqual(sprung.spring, .niri)
        XCTAssertNotEqual(sprung.duration, 0.2)
    }

    // MARK: - Retarget

    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 0
        var reading: ReflowClock { { [self] in now } }
    }

    private final class FakeSink: MotionFrameSink {
        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool { true }
        func waitForMotionIdle(timeout: TimeInterval) {}
        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    func testRetargetKeepsPositionAndVelocityContinuous() {
        let clock = FakeClock()
        let player = MotionPlayer(sink: FakeSink(), clock: clock.reading)
        let first = slide(id(1), from: 0, to: 1000)
        player.start([first])
        clock.now = 0.05
        let tick = player.tick()
        let sampled = tick.sampled[id(1)]!
        let speed = first.velocity(at: 0.05).x
        XCTAssertGreaterThan(speed, 500)
        // The planner builds the retarget from the sampled frame.
        let next = WindowAnimation(
            id: id(1), from: sampled, to: CGRect(x: 1400, y: 0, width: 300, height: 400), spring: .niri
        )
        player.start([next])
        let retargeted = player.currentAnimations[0]
        XCTAssertEqual(retargeted.frame(at: 0).origin.x, sampled.origin.x, accuracy: 1e-9)
        XCTAssertEqual(retargeted.velocity(at: 0).x, speed, accuracy: 1e-6)
        // Position stays continuous a hair later: no restart from rest.
        let later = retargeted.frame(at: 0.001).origin.x
        XCTAssertEqual(later, sampled.origin.x + speed * 0.001, accuracy: 3)
    }

    func testRetargetWithoutAFlightStartsAtRest() {
        let clock = FakeClock()
        let player = MotionPlayer(sink: FakeSink(), clock: clock.reading)
        player.start([slide(id(1))])
        XCTAssertEqual(player.currentAnimations[0].velocity, .zero)
        let finished = player.currentAnimations[0]
        clock.now = finished.duration + 0.1
        XCTAssertNotNil(player.tick().summary)
        player.start([slide(id(1), from: 800, to: 0)])
        XCTAssertEqual(player.currentAnimations[0].velocity, .zero)
    }

    func testSummaryNamesTheCurve() {
        let clock = FakeClock()
        let player = MotionPlayer(sink: FakeSink(), clock: clock.reading)
        let animation = slide(id(1))
        player.start([animation])
        clock.now = animation.duration + 0.01
        let summary = player.tick().summary
        XCTAssertEqual(summary?.curve, "spring")
        XCTAssertTrue(summary?.logLine.hasSuffix(" curve=spring sizeAnimated=0") ?? false)
    }


    // MARK: - PA-03 completion threshold

    func testSpringEndsUnderHalfAPointOfResidualAndSmallVelocity() {
        XCTAssertEqual(SpringParameters.minimumThreshold, 0.5)
        let spring = SpringParameters.niri
        // A short flight: the point floor (not epsilon * travel) decides.
        let settle = spring.settleTime(axes: [(displacement: 40, velocity: 0)])
        let atSettle = spring.state(displacement: 40, velocity: 0, at: settle)
        XCTAssertLessThan(abs(atSettle.displacement), 0.5)
        XCTAssertLessThan(abs(atSettle.velocity), 30)
        // No later than the first instant the residual and velocity are both small.
        var t = 0.0
        while t < 1 {
            let s = spring.state(displacement: 40, velocity: 0, at: t)
            if abs(s.displacement) < 0.5 && abs(s.velocity) < 30 {
                var stays = true
                var u = t
                while u < 1 {
                    let n = spring.state(displacement: 40, velocity: 0, at: u)
                    if abs(n.displacement) >= 0.5 || abs(n.velocity) >= 30 { stays = false; break }
                    u += 0.004
                }
                if stays { break }
            }
            t += 0.004
        }
        XCTAssertLessThanOrEqual(settle, t + 0.02)
    }
}
