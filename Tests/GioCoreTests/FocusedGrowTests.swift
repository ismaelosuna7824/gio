import XCTest
@testable import GioCore

/// The focused window that grows gets its final size in the first frame of the
/// motion and only its origin flies (`[animations] focused-grow`).
final class FocusedGrowTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 0
        var reading: ReflowClock { { [self] in now } }
    }

    private final class FakeSink: MotionFrameSink {
        var accepted: [(pid: pid_t, writes: [MotionWrite])] = []
        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            accepted.append((pid, writes))
            return true
        }
        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func grower(_ window: WindowID, x: CGFloat = 500) -> WindowAnimation {
        WindowAnimation(
            id: window, from: CGRect(x: x, y: 0, width: 500, height: 800),
            to: CGRect(x: 0, y: 0, width: 1500, height: 800), duration: 1, easing: .linear
        )
    }

    private func slider(_ window: WindowID) -> WindowAnimation {
        WindowAnimation(
            id: window, from: CGRect(x: 0, y: 0, width: 400, height: 800),
            to: CGRect(x: 1500, y: 0, width: 400, height: 800), duration: 1, easing: .linear
        )
    }

    private func schedules(_ animations: [WindowAnimation]) -> [SizeSchedule] {
        animations.map(\.sizeSchedule)
    }

    // MARK: motionFrame

    func testAtStartWritesTheFinalSizeFromTheFirstFrameAndOnlyTheOriginFlies() {
        var animation = grower(id(1))
        animation.sizeSchedule = .atStart
        for elapsed in [0.0, 0.001, 0.25, 0.5, 0.9] {
            XCTAssertEqual(animation.motionFrame(at: elapsed).size, CGSize(width: 1500, height: 800))
        }
        XCTAssertEqual(animation.motionFrame(at: 0.5).minX, 250, accuracy: 1e-9)
        XCTAssertEqual(animation.motionFrame(at: 1), animation.to)
    }

    func testAtStartKeepsShrinkingDimensionOnTheFirstFrame() {
        var animation = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 400, height: 900),
            to: CGRect(x: 0, y: 0, width: 800, height: 600), duration: 1, easing: .linear
        )
        animation.sizeSchedule = .atStart
        XCTAssertEqual(animation.motionFrame(at: 0.1).size, CGSize(width: 800, height: 600))
    }

    func testAtStartHoldsTheOldSizeBeforeTheFlightBegins() {
        var animation = grower(id(1))
        animation.sizeSchedule = .atStart
        XCTAssertEqual(animation.motionFrame(at: -0.1).width, 500)
    }

    // MARK: planner

    func testOnlyTheFocusedGrowingWindowGetsAtStart() {
        let planned = planSizeSchedules(
            [grower(id(1)), grower(id(2), x: 700), slider(id(3))],
            mode: .never, capablePids: [], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.atStart, .none, .none])
    }

    func testFocusedShrinkOrNoGrowthKeepsFI03() {
        let shrinking = WindowAnimation(
            id: id(1), from: CGRect(x: 0, y: 0, width: 900, height: 800),
            to: CGRect(x: 0, y: 0, width: 400, height: 800), duration: 1, easing: .linear
        )
        let planned = planSizeSchedules(
            [shrinking, slider(id(2))], mode: .never, capablePids: [], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.none, .none])
        let moved = planSizeSchedules(
            [slider(id(2))], mode: .never, capablePids: [], focused: id(2), focusedGrow: .start
        )
        XCTAssertEqual(schedules(moved), [.none])
    }

    func testNoFocusIntentOrEndSettingKeepsFI03() {
        let animations = [grower(id(1)), slider(id(2))]
        XCTAssertEqual(
            schedules(planSizeSchedules(
                animations, mode: .never, capablePids: [], focused: nil, focusedGrow: .start
            )),
            [.none, .none]
        )
        XCTAssertEqual(
            schedules(planSizeSchedules(
                animations, mode: .never, capablePids: [], focused: id(1), focusedGrow: .end
            )),
            [.none, .none]
        )
        XCTAssertEqual(
            schedules(planSizeSchedules(animations, mode: .never, capablePids: [])), [.none, .none],
            "the defaults preserve the previous behaviour"
        )
    }

    func testFocusedWindowNotAnimatingIsIgnored() {
        let planned = planSizeSchedules(
            [slider(id(2))], mode: .never, capablePids: [], focused: id(9), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.none])
    }

    // MARK: precedence with [animations] resize

    func testAdaptiveKeepsAnInterpolatingScheduleForTheFocusedWindow() {
        // Alone in the scene: nothing in the way, capable app -> fromStart stays.
        let planned = planSizeSchedules(
            [grower(id(1))], mode: .adaptive, capablePids: [10], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.fromStart])
    }

    func testAdaptiveKeepsADelayedGrowForTheFocusedWindow() {
        // A neighbour to the right starts slowly (ease-in-out): growing from
        // the first frame would overlap it, so the planner delays the grow.
        let neighbour = WindowAnimation(
            id: id(2, pid: 20), from: CGRect(x: 1000, y: 0, width: 500, height: 800),
            to: CGRect(x: 2000, y: 0, width: 500, height: 800), duration: 1, easing: .easeInOut
        )
        let focused = WindowAnimation(
            id: id(1), from: CGRect(x: 500, y: 0, width: 500, height: 800),
            to: CGRect(x: 500, y: 0, width: 1000, height: 800), duration: 1, easing: .linear
        )
        let planned = planSizeSchedules(
            [focused, neighbour], mode: .adaptive, capablePids: [10], focused: id(1), focusedGrow: .start
        )
        guard case .from = planned[0].sizeSchedule else {
            return XCTFail("expected the planner's delayed grow, got \(planned[0].sizeSchedule)")
        }
    }

    func testAdaptiveFallsBackToAtStartWhenThePlannerDoesNotInterpolate() {
        let planned = planSizeSchedules(
            [grower(id(1))], mode: .adaptive, capablePids: [], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.atStart])
    }

    func testAlwaysWithNoClearWindowFallsBackToAtStart() {
        // The neighbour never leaves: no candidate start is clear.
        let stuck = WindowAnimation(
            id: id(2, pid: 20), from: CGRect(x: 500, y: 0, width: 500, height: 800),
            to: CGRect(x: 500, y: 0, width: 500, height: 800), duration: 1, easing: .linear
        )
        let planned = planSizeSchedules(
            [grower(id(1)), stuck], mode: .always, capablePids: [], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(schedules(planned), [.atStart, .none])
    }

    func testAdaptiveEndSettingLeavesTheFocusedWindowOnFI03WhenNotCapable() {
        let planned = planSizeSchedules(
            [grower(id(1))], mode: .adaptive, capablePids: [], focused: id(1), focusedGrow: .end
        )
        XCTAssertEqual(schedules(planned), [.none])
    }

    func testOtherWindowsKeepTheirAdaptivePolicyNextToAFocusedAtStart() {
        let other = WindowAnimation(
            id: id(2, pid: 20), from: CGRect(x: 2000, y: 0, width: 300, height: 800),
            to: CGRect(x: 2600, y: 0, width: 500, height: 800), duration: 1, easing: .linear
        )
        let planned = planSizeSchedules(
            [grower(id(1)), other], mode: .adaptive, capablePids: [20], focused: id(1), focusedGrow: .start
        )
        XCTAssertEqual(planned[0].sizeSchedule, .atStart)
        XCTAssertEqual(planned[1].sizeSchedule, .fromStart)
    }

    // MARK: player

    func testPlayerWritesTheFinalSizeInTheFirstFrameOnceAndCountsGrewAtStart() {
        let clock = FakeClock(), sink = FakeSink()
        let player = MotionPlayer(sink: sink, clock: clock.reading, appName: { "app\($0)" })
        var animation = grower(id(1))
        animation.sizeSchedule = .atStart
        player.start([animation, slider(id(2, pid: 30))])
        clock.now = 0.02
        _ = player.tick()
        let first = sink.accepted.first { $0.pid == 10 }?.writes.first
        XCTAssertEqual(first?.to.size, CGSize(width: 1500, height: 800))
        clock.now = 0.5
        _ = player.tick()
        let second = sink.accepted.last { $0.pid == 10 }?.writes.first
        XCTAssertEqual(second?.from.size, second?.to.size, "later frames are position only")
        clock.now = 1
        let summary = player.tick().summary
        XCTAssertEqual(summary?.grewAtStart, 1)
        XCTAssertEqual(summary?.sizeAnimated, 0, "the size is not interpolated")
        XCTAssertTrue(summary?.logLine.hasSuffix("renderer=ax grewAtStart=1") ?? false)
    }

    func testSummaryLineCarriesGrewAtStartZeroByDefault() {
        let summary = MotionSummary(windows: 1, frames: 2, dropped: 0, duration: 0.2, slowest: nil)
        XCTAssertTrue(summary.logLine.hasSuffix("sizeAnimated=0 renderer=ax grewAtStart=0"))
    }

    // MARK: focus intent

    func testPendingTargetPeeksWithoutConsumingAndSkipsParked() {
        var intent = FocusIntent()
        XCTAssertNil(intent.pendingTarget(parked: []))
        intent.request(id(1), now: 0)
        XCTAssertEqual(intent.pendingTarget(parked: []), id(1))
        XCTAssertEqual(intent.pendingTarget(parked: []), id(1), "peeking does not consume")
        XCTAssertNil(intent.pendingTarget(parked: [id(1)]))
        XCTAssertEqual(intent.takeImmediate(parked: [], now: 0), id(1))
        XCTAssertNil(intent.pendingTarget(parked: []))
    }

    func testSizingActionsResizeTheFocusedWindowWithoutMovingFocus() {
        let sizing: [HotkeyAction] = [
            .switchPresetColumnWidth, .growColumnWidth, .shrinkColumnWidth, .maximizeColumn,
            .switchPresetWindowHeight, .growWindowHeight, .shrinkWindowHeight, .resetWindowHeight,
        ]
        for action in sizing {
            XCTAssertTrue(action.growsFocusedWindow, "\(action)")
            XCTAssertFalse(action.carriesFocusIntent, "\(action)")
        }
        XCTAssertFalse(HotkeyAction.focusLeft.growsFocusedWindow)
        XCTAssertFalse(HotkeyAction.centerColumn.growsFocusedWindow)
        XCTAssertFalse(HotkeyAction.toggleFloating.growsFocusedWindow)
    }

    // MARK: config

    func testFocusedGrowDefaultsToStartAndParses() throws {
        XCTAssertEqual(defaultGioConfig().animations.focusedGrow, .start)
        for mode in ["start", "end"] {
            let (config, warnings) = try parseGioConfig("[animations]\nfocused-grow = \"\(mode)\"\n").get()
            XCTAssertTrue(warnings.isEmpty)
            XCTAssertEqual(config.animations.focusedGrow.rawValue, mode)
        }
    }

    func testUnknownFocusedGrowWarnsAndNonStringIsAnError() throws {
        let (config, warnings) = try parseGioConfig("[animations]\nfocused-grow = \"middle\"\n").get()
        XCTAssertEqual(config.animations.focusedGrow, .start)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("animations.focused-grow"))
        XCTAssertThrowsError(try parseGioConfig("[animations]\nfocused-grow = 3\n").get())
    }

    func testTemplateDeclaresFocusedGrowAndEditsCarryIt() throws {
        XCTAssertTrue(defaultConfigTemplate().contains("focused-grow = \"start\""))
        let (config, warnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.animations.focusedGrow, .start)
        XCTAssertEqual(
            animationEdits(enabled: true, durationMilliseconds: 200, focusedGrow: .end).last,
            .set(table: "animations", key: "focused-grow", value: .string("end"))
        )
        XCTAssertFalse(
            animationEdits(enabled: true, durationMilliseconds: 200).contains {
                if case .set(_, "focused-grow", _) = $0 { return true } else { return false }
            }
        )
    }
}
