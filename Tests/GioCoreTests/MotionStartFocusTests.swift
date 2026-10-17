import XCTest
@testable import GioCore

/// PF-Q: the keyboard focus at a motion's start (FI-06) runs off the
/// caller's queue. `focusAXWindow` activates the app and polls until it is
/// frontmost (12-45 ms live, 2026-10-12 log: `hotkey focusLeft` 02:49:57.201,
/// `focus now` 57.223); on the session queue that held the first tick of every
/// flight and every retarget's next tick.
final class MotionStartFocusTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private final class BlockingActuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        let gate = DispatchSemaphore(value: 0)
        let blocking: Set<WindowID>
        let refusing: Set<WindowID>

        init(blocking: Set<WindowID> = [], refusing: Set<WindowID> = []) {
            self.blocking = blocking
            self.refusing = refusing
        }

        var lines: [String] { lock.withLock { entries } }

        func frame(of id: WindowID) throws -> CGRect? { nil }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {}

        func focus(id: WindowID) throws {
            if blocking.contains(id) {
                gate.wait()
            }
            if refusing.contains(id) {
                throw FocusRefused()
            }
            lock.withLock { entries.append("focus \(id.elementID)") }
        }
    }

    private struct FocusRefused: Error {}

    func testAMotionStartFocusDoesNotHoldTheCaller() {
        let actuator = BlockingActuator(blocking: [id(1)])
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let started = ProcessInfo.processInfo.systemUptime
        reconciler.focusSoon(id(1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.05)
        XCTAssertTrue(actuator.lines.isEmpty, "the focus call is still running elsewhere")
        XCTAssertFalse(reconciler.waitForFocusIdle(timeout: 0.02))
        actuator.gate.signal()
        XCTAssertTrue(reconciler.waitForFocusIdle(timeout: 2))
        XCTAssertEqual(actuator.lines, ["focus 1"])
    }

    func testTheNewestMotionStartFocusLandsAndTheSettleFocusComesAfterIt() {
        let actuator = BlockingActuator(blocking: [id(1)])
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        reconciler.focusSoon(id(1))
        reconciler.focusSoon(id(2))
        let gate = actuator.gate
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        // The final pass focuses last; a motion-start focus still running
        // must not land after it. PF-AN: focus 1 runs only when the queue
        // started it before focus 2 was issued.
        reconciler.reconcile(frames: [:], focused: id(3), currentlyFocused: nil)
        XCTAssertEqual(actuator.lines.filter { $0 != "focus 1" }, ["focus 2", "focus 3"])
        XCTAssertTrue(["focus 1", "focus 2", "focus 3"].suffix(actuator.lines.count) == ArraySlice(actuator.lines))
    }

    func testARefusedMotionStartFocusIsLoggedOnce() {
        GioLog.clearForTests()
        GioLog.logFilePath = NSTemporaryDirectory() + "gio-pfq-\(UUID().uuidString).log"
        let actuator = BlockingActuator(refusing: [id(4)])
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, appName: { _ in "Xcode" })
        reconciler.focusSoon(id(4))
        reconciler.focusSoon(id(4))
        XCTAssertTrue(reconciler.waitForFocusIdle(timeout: 2))
        let lines = GioLog.entries().filter { $0.message.hasPrefix("focus failed id=10:4") }
        XCTAssertEqual(lines.count, 1, "the PF-I gate holds the repeat back")
    }

    /// PF-AN: a burst of key presses queues three focus calls; by the time
    /// the queue reaches them only the newest still matters.
    func testABurstOfMotionStartFocusesRunsOnlyTheNewest() {
        GioLog.clearForTests()
        GioLog.logFilePath = NSTemporaryDirectory() + "gio-pfan-\(UUID().uuidString).log"
        let actuator = BlockingActuator()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        var queued: [@Sendable () -> Void] = []
        reconciler.focusSubmit = { queued.append($0) }
        reconciler.focusSoon(id(1))
        reconciler.focusSoon(id(2))
        reconciler.focusSoon(id(3))
        XCTAssertFalse(reconciler.waitForFocusIdle(timeout: 0.01))
        queued.forEach { $0() }
        XCTAssertEqual(actuator.lines, ["focus 3"])
        XCTAssertTrue(reconciler.waitForFocusIdle(timeout: 0.01))
        let superseded = GioLog.entries(minLevel: .debug).filter { $0.message.hasPrefix("focus superseded") }
        XCTAssertEqual(superseded.map(\.message), ["focus superseded id=10:1", "focus superseded id=10:2"])
    }

    func testASingleMotionStartFocusStillRuns() {
        let actuator = BlockingActuator()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        var queued: [@Sendable () -> Void] = []
        reconciler.focusSubmit = { queued.append($0) }
        reconciler.focusSoon(id(1))
        queued.forEach { $0() }
        XCTAssertEqual(actuator.lines, ["focus 1"])
    }
}
