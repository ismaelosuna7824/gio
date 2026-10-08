import Foundation
import GioCore
import XCTest
@testable import GioSession

/// PF-A: windows the final pass deferred (their app was still busy with a
/// motion write) get one more final pass as soon as that app is idle.
final class DeferredSettleTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var busy: Set<pid_t> = []
        var motionActive = false
        var passes = 0
        var logs: [String] = []
    }

    private var world: World!
    private var scheduler: ManualScheduler!

    override func setUp() {
        world = World()
        scheduler = ManualScheduler()
    }

    private func make() -> DeferredSettle {
        let world = world!
        return DeferredSettle(
            context: .init(
                isBusy: { pids in !world.busy.isDisjoint(with: pids) },
                isMotionActive: { world.motionActive },
                finalPass: { world.passes += 1 },
                log: { _, line in world.logs.append(line) }
            ),
            scheduler: scheduler
        )
    }

    func testRunsOneFinalPassOnceTheAppIsIdle() {
        let settle = make()
        world.busy = [7]
        settle.defer([WindowID(pid: 7, elementID: 1)])
        scheduler.advance(by: DeferredSettle.pollInterval * 3)
        XCTAssertEqual(world.passes, 0, "still writing: no pass yet")
        world.busy = []
        scheduler.advance(by: DeferredSettle.pollInterval)
        XCTAssertEqual(world.passes, 1)
        scheduler.advance(by: 1)
        XCTAssertEqual(world.passes, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDeferralsWhilePollingShareOnePass() {
        let settle = make()
        world.busy = [7, 8]
        settle.defer([WindowID(pid: 7, elementID: 1)])
        settle.defer([WindowID(pid: 8, elementID: 2)])
        world.busy = [8]
        scheduler.advance(by: DeferredSettle.pollInterval)
        XCTAssertEqual(world.passes, 0, "pid 8 is still writing")
        world.busy = []
        scheduler.advance(by: DeferredSettle.pollInterval)
        XCTAssertEqual(world.passes, 1)
    }

    func testAStuckAppGetsThePassAtTheDeadlineAnyway() {
        let settle = make()
        world.busy = [7]
        settle.defer([WindowID(pid: 7, elementID: 1)])
        scheduler.advance(by: DeferredSettle.deadline + DeferredSettle.pollInterval)
        XCTAssertEqual(world.passes, 1)
        XCTAssertEqual(world.logs.filter { $0.hasPrefix("settle deferred timeout") }.count, 1)
    }

    func testANewMotionTakesOverTheSettle() {
        let settle = make()
        world.busy = []
        settle.defer([WindowID(pid: 7, elementID: 1)])
        world.motionActive = true
        scheduler.advance(by: 1)
        XCTAssertEqual(world.passes, 0, "the motion's own final pass settles the window")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }
}
