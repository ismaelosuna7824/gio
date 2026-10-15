import XCTest
@testable import GioUI

/// PA-02: nothing polls unless the main window is visible and the section
/// is on screen; the menu bar only reacts to real state changes.
final class IdlePolicyTests: XCTestCase {
    func testPollsOnlyWhileWindowVisibleAndSectionOnScreen() {
        XCTAssertTrue(shouldPoll(windowVisible: true, sectionOnScreen: true))
        XCTAssertFalse(shouldPoll(windowVisible: false, sectionOnScreen: true))
        XCTAssertFalse(shouldPoll(windowVisible: true, sectionOnScreen: false))
        XCTAssertFalse(shouldPoll(windowVisible: false, sectionOnScreen: false))
    }

    func testBarStateGateAcceptsOnlyChanges() {
        var gate = BarStateGate()
        let a = BarSessionState(workspace: 1, windows: 2, columns: 2, focused: nil)
        XCTAssertTrue(gate.accept(a), "first state always passes")
        XCTAssertFalse(gate.accept(a))
        XCTAssertTrue(gate.accept(BarSessionState(workspace: 2, windows: 2, columns: 2, focused: nil)))
        XCTAssertTrue(gate.accept(nil), "losing the session is a change")
        XCTAssertFalse(gate.accept(nil))
    }

    @MainActor
    func testModelRefreshesWhenWindowBecomesVisibleOnly() {
        let counter = Counter()
        let model = DesktopModel(fetch: { counter.bump(); return SessionSnapshot() })
        var fetches: Int { counter.value }
        let base = fetches
        model.setWindowVisible(false)
        XCTAssertFalse(model.windowVisible)
        XCTAssertEqual(fetches, base)
        model.setWindowVisible(false)
        XCTAssertEqual(fetches, base, "no change, no fetch")
        model.setWindowVisible(true)
        XCTAssertTrue(model.windowVisible)
        XCTAssertEqual(fetches, base + 1)
    }

    /// PF-AG: every Gio flight puts a display-sized overlay over the main
    /// window, so its occlusion flipped hidden and back twice per action and
    /// each flip re-rendered the whole SwiftUI window (two bursts per action
    /// in the workload trace). Coming into view counts at once; being
    /// covered only once it lasted `hideDelay`.
    func testBriefOcclusionKeepsTheWindowVisibleAndALongOneHidesIt() {
        var gate = OcclusionGate()
        let flight = gate.occluded()
        gate.uncovered()
        XCTAssertFalse(gate.shouldHide(flight), "a covered moment shorter than the delay")

        let real = gate.occluded()
        XCTAssertTrue(gate.shouldHide(real), "still covered when the delay ends")
        XCTAssertGreaterThanOrEqual(OcclusionGate.hideDelay, 0.5, "longer than a flight")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
