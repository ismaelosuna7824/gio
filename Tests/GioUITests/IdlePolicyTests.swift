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
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
