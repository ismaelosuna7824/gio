import XCTest
@testable import GioCore

/// PA-06: windows whose app keeps up grow during the flight instead of at the
/// final pass, when nothing is in their way.
final class AdaptiveSizeTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func fast(count: Int = 20) -> MotionWriteStats {
        MotionWriteStats(count: count, sumMilliseconds: Double(count) * 1.5, maxMilliseconds: 3, drops: 0, axCalls: 0)
    }

    private func slow(count: Int = 20) -> MotionWriteStats {
        MotionWriteStats(count: count, sumMilliseconds: Double(count) * 12, maxMilliseconds: 30, drops: 0, axCalls: 0)
    }

    // MARK: capability

    func testUnknownAppStartsConservativeAndLearnsAfterTwoSamples() {
        var capability = ResizeCapability()
        XCTAssertFalse(capability.canAnimateSize("Terminal"))
        _ = capability.record("Terminal", stats: fast())
        XCTAssertFalse(capability.canAnimateSize("Terminal"), "one sample is not enough")
        let changed = capability.record("Terminal", stats: fast())
        XCTAssertTrue(changed)
        XCTAssertTrue(capability.canAnimateSize("Terminal"))
    }

    func testSlowAppNeverQualifiesAndFastAppLosesItWhenItSlowsDown() {
        var capability = ResizeCapability()
        for _ in 0..<4 { _ = capability.record("Electron", stats: slow()) }
        XCTAssertFalse(capability.canAnimateSize("Electron"))

        for _ in 0..<3 { _ = capability.record("Fast", stats: fast()) }
        XCTAssertTrue(capability.canAnimateSize("Fast"))
        var flipped = false
        for _ in 0..<4 { flipped = capability.record("Fast", stats: slow()) || flipped }
        XCTAssertTrue(flipped)
        XCTAssertFalse(capability.canAnimateSize("Fast"))
    }

    func testDropRateAboveTenPercentDisqualifies() {
        var capability = ResizeCapability()
        let dropping = MotionWriteStats(count: 10, sumMilliseconds: 15, maxMilliseconds: 3, drops: 5, axCalls: 0)
        for _ in 0..<3 { _ = capability.record("Dropper", stats: dropping) }
        XCTAssertFalse(capability.canAnimateSize("Dropper"))
        let snapshot = capability.metrics("Dropper")
        XCTAssertEqual(snapshot?.dropRate ?? 0, 5.0 / 15.0, accuracy: 1e-9)
    }

    func testClampBlocksUntilCleanMotionsPass() {
        var capability = ResizeCapability()
        for _ in 0..<3 { _ = capability.record("Clamper", stats: fast()) }
        XCTAssertTrue(capability.canAnimateSize("Clamper"))
        XCTAssertTrue(capability.noteClamp("Clamper"))
        XCTAssertFalse(capability.canAnimateSize("Clamper"))
        for _ in 0..<ResizeCapability.clampCooldownMotions { _ = capability.record("Clamper", stats: fast()) }
        XCTAssertTrue(capability.canAnimateSize("Clamper"))
    }

    func testTinySamplesAreIgnored() {
        var capability = ResizeCapability()
        for _ in 0..<5 {
            _ = capability.record("Tiny", stats: MotionWriteStats(count: 1, sumMilliseconds: 1, maxMilliseconds: 1))
        }
        XCTAssertFalse(capability.canAnimateSize("Tiny"))
        XCTAssertNil(capability.metrics("Tiny"))
    }

    // MARK: motionFrame honours the schedule

    private func grower(schedule: SizeSchedule) -> WindowAnimation {
        var animation = WindowAnimation(
            id: id(1), from: CGRect(x: 500, y: 0, width: 500, height: 800),
            to: CGRect(x: 0, y: 0, width: 1500, height: 800), duration: 1, easing: .linear
        )
        animation.sizeSchedule = schedule
        return animation
    }

    func testNoScheduleKeepsFI03GrowAtFinalPass() {
        let frame = grower(schedule: .none).motionFrame(at: 0.5)
        XCTAssertEqual(frame.width, 500)
        XCTAssertEqual(frame.minX, 250, accuracy: 1e-9)
    }

    func testFromStartInterpolatesWidthWithTheOrigin() {
        let animation = grower(schedule: .fromStart)
        let frame = animation.motionFrame(at: 0.5)
        XCTAssertEqual(frame.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 800)
        XCTAssertEqual(animation.motionFrame(at: 1), animation.to)
    }

    func testShrinkingDimensionStillDropsOnTheFirstFrame() {
        var animation = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 400, height: 900),
            to: CGRect(x: 0, y: 0, width: 800, height: 600), duration: 1, easing: .linear
        )
        animation.sizeSchedule = .fromStart
        let frame = animation.motionFrame(at: 0.25)
        XCTAssertEqual(frame.height, 600, "shrinks stay on the first frame (FI-03)")
        XCTAssertEqual(frame.width, 500, accuracy: 1e-9)
    }

    func testDelayedScheduleHoldsThenReachesTargetAtTheEnd() {
        let animation = grower(schedule: .from(0.5))
        XCTAssertEqual(animation.motionFrame(at: 0.4).width, 500)
        XCTAssertEqual(animation.motionFrame(at: 0.5).width, 500, accuracy: 1e-9)
        XCTAssertEqual(animation.motionFrame(at: 0.75).width, 1000, accuracy: 1e-9)
        XCTAssertEqual(animation.motionFrame(at: 1).width, 1500)
    }

    func testSpringSizeProgressIsTheNormalizedOriginProgress() {
        var animation = WindowAnimation(
            id: id(1), from: CGRect(x: 500, y: 0, width: 500, height: 800),
            to: CGRect(x: 0, y: 0, width: 1500, height: 800), spring: .niri
        )
        animation.sizeSchedule = .fromStart
        for fraction in [0.1, 0.3, 0.6] {
            let elapsed = animation.duration * fraction
            let progress = animation.normalizedProgress(at: elapsed)
            let frame = animation.motionFrame(at: elapsed)
            XCTAssertEqual(progress, (500 - frame.minX) / 500, accuracy: 1e-9)
            XCTAssertEqual(frame.width, 500 + 1000 * progress, accuracy: 1e-9)
            XCTAssertTrue((0...1).contains(progress))
        }
    }

    func testSpringingKeepsTheSchedule() {
        let animation = grower(schedule: .from(0.25)).springing(.niri)
        XCTAssertEqual(animation.sizeSchedule, .from(0.25))
    }

    // MARK: planner: maximize scenario

    /// Focused column grows to the full width while both neighbours retreat.
    private func maximize(easing: AnimationEasing = .easeOut) -> [WindowAnimation] {
        [
            WindowAnimation(
                id: id(1, pid: 10), from: CGRect(x: 0, y: 0, width: 500, height: 800),
                to: CGRect(x: -500, y: 0, width: 500, height: 800), duration: 0.3, easing: easing
            ),
            WindowAnimation(
                id: id(2, pid: 20), from: CGRect(x: 500, y: 0, width: 500, height: 800),
                to: CGRect(x: 0, y: 0, width: 1500, height: 800), duration: 0.3, easing: easing
            ),
            WindowAnimation(
                id: id(3, pid: 30), from: CGRect(x: 1000, y: 0, width: 500, height: 800),
                to: CGRect(x: 1500, y: 0, width: 500, height: 800), duration: 0.3, easing: easing
            ),
        ]
    }

    private func assertNoOverlap(_ animations: [WindowAnimation], file: StaticString = #filePath, line: UInt = #line) {
        for step in 1...19 {
            let elapsed = 0.3 * Double(step) / 20
            let frames = animations.map { $0.motionFrame(at: elapsed) }
            for a in 0..<frames.count {
                for b in (a + 1)..<frames.count {
                    let overlap = frames[a].intersection(frames[b])
                    XCTAssertFalse(
                        !overlap.isNull && overlap.width > 1 && overlap.height > 1,
                        "overlap between \(a) and \(b) at \(elapsed)", file: file, line: line
                    )
                }
            }
        }
    }

    func testMaximizeOnAFastAppInterpolatesSizeWithoutOverlap() {
        let planned = planSizeSchedules(maximize(), mode: .adaptive, capablePids: [20])
        XCTAssertEqual(planned.first { $0.id == id(2, pid: 20) }?.sizeSchedule, .fromStart)
        XCTAssertEqual(planned.filter { $0.sizeSchedule != .none }.count, 1)
        assertNoOverlap(planned)
        XCTAssertGreaterThan(planned[1].motionFrame(at: 0.15).width, 500)
    }

    func testMaximizeOnASlowAppKeepsFI03() {
        let planned = planSizeSchedules(maximize(), mode: .adaptive, capablePids: [])
        XCTAssertTrue(planned.allSatisfy { $0.sizeSchedule == .none })
        XCTAssertEqual(planned[1].motionFrame(at: 0.15).width, 500)
    }

    func testNeverModeDisablesEvenForCapableApps() {
        let planned = planSizeSchedules(maximize(), mode: .never, capablePids: [10, 20, 30])
        XCTAssertTrue(planned.allSatisfy { $0.sizeSchedule == .none })
    }

    func testAlwaysModeIgnoresCapabilityButStillChecksOverlap() {
        let planned = planSizeSchedules(maximize(), mode: .always, capablePids: [])
        XCTAssertEqual(planned[1].sizeSchedule, .fromStart)

        // A neighbour that does not move at all blocks any growth.
        var blocked = maximize()
        blocked[2] = WindowAnimation(
            id: id(3, pid: 30), from: CGRect(x: 1000, y: 0, width: 500, height: 800),
            to: CGRect(x: 1000, y: 100, width: 500, height: 800), duration: 0.3, easing: .easeOut
        )
        let result = planSizeSchedules(blocked, mode: .always, capablePids: [])
        XCTAssertEqual(result[1].sizeSchedule, .none)
    }

    func testShrinkOnlyWindowsGetNoSchedule() {
        let shrinking = [
            WindowAnimation(
                id: id(1), from: CGRect(x: 0, y: 0, width: 800, height: 600),
                to: CGRect(x: 0, y: 0, width: 400, height: 600), duration: 0.2, easing: .linear
            ),
        ]
        XCTAssertEqual(planSizeSchedules(shrinking, mode: .always, capablePids: []).first?.sizeSchedule, SizeSchedule.none)
    }

    func testDelayedGrowStartsWhenTheNeighbourHasCleared() {
        // The neighbour eases in slowly, so the grower must wait for it.
        let grow = WindowAnimation(
            id: id(1, pid: 10), from: CGRect(x: 0, y: 0, width: 500, height: 800),
            to: CGRect(x: 0, y: 0, width: 800, height: 800), duration: 1, easing: .linear
        )
        let neighbour = WindowAnimation(
            id: id(2, pid: 20), from: CGRect(x: 500, y: 0, width: 500, height: 800),
            to: CGRect(x: 800, y: 0, width: 500, height: 800), duration: 1, easing: .easeInOut
        )
        let planned = planSizeSchedules([grow, neighbour], mode: .always, capablePids: [])
        guard case .from(let start) = planned[0].sizeSchedule else {
            return XCTFail("expected a delayed grow, got \(planned[0].sizeSchedule)")
        }
        XCTAssertGreaterThan(start, 0)
        XCTAssertLessThan(start, 1)
        for step in 1...19 {
            let elapsed = Double(step) / 20
            let overlap = planned[0].motionFrame(at: elapsed).intersection(planned[1].motionFrame(at: elapsed))
            XCTAssertFalse(!overlap.isNull && overlap.width > 1 && overlap.height > 1, "overlap at \(elapsed)")
        }
        // Earlier starts on the grid would have overlapped.
        XCTAssertNil(
            delayedGrowStart(for: grow, among: [neighbour], candidates: [max(0, start - 0.05)])
        )
        XCTAssertEqual(planned[0].motionFrame(at: 1), grow.to)
    }
}
