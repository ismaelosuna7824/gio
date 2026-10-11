import XCTest
@testable import GioCore

/// PF-K: `AXEnhancedUserInterface` is off while Gio writes an app's frames
/// and back on right after; never touched for Gio's own pid.
final class EnhancedUserInterfaceTests: XCTestCase {
    /// Records every read and write in one shared log.
    final class Switch: EnhancedUserInterfaceSwitch, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [pid_t: Bool]
        private var log: [String] = []
        /// Apps that do not take the restore (`true`), like a hung app.
        var refusingRestore: Set<pid_t> = []
        var unreadable: Set<pid_t> = []
        let journal: Journal?

        init(_ values: [pid_t: Bool], journal: Journal? = nil) {
            self.values = values
            self.journal = journal
        }

        var calls: [String] { lock.withLock { log } }

        func value(_ pid: pid_t) -> Bool? { lock.withLock { values[pid] } }

        func enhancedUserInterface(pid: pid_t) -> Bool? {
            record("read \(pid)")
            return lock.withLock { unreadable.contains(pid) ? nil : values[pid] }
        }

        func setEnhancedUserInterface(_ on: Bool, pid: pid_t) -> Bool {
            record("set \(pid) \(on)")
            return lock.withLock {
                guard !(on && refusingRestore.contains(pid)) else { return false }
                values[pid] = on
                return true
            }
        }

        private func record(_ line: String) {
            lock.withLock { log.append(line) }
            journal?.append(line)
        }
    }

    /// One ordered log shared by the switch and an actuator.
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ line: String) { lock.withLock { entries.append(line) } }
        var lines: [String] { lock.withLock { entries } }
    }

    final class Clock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    // MARK: Guard

    func testAnAppWithItOnIsSwitchedOffForTheBatchAndBackOnAtItsEnd() {
        let control = Switch([10: true])
        let guardian = EnhancedUIGuard(control: control, ownPID: 1)
        guardian.willWrite(pid: 10)
        XCTAssertEqual(control.value(10), false)
        guardian.willWrite(pid: 10)
        guardian.batchEnded(pid: 10)
        XCTAssertEqual(control.calls, ["read 10", "set 10 false", "set 10 true"])
        XCTAssertEqual(control.value(10), true)
        XCTAssertTrue(guardian.pendingRestores.isEmpty)
    }

    func testAnAppWithItOffOrUnreadableIsNeverWritten() {
        let control = Switch([10: false, 11: true])
        control.unreadable = [11]
        let guardian = EnhancedUIGuard(control: control, ownPID: 1)
        for pid: pid_t in [10, 11] {
            guardian.willWrite(pid: pid)
            guardian.batchEnded(pid: pid)
        }
        XCTAssertEqual(control.calls, ["read 10", "read 11"])
    }

    func testGiosOwnPidIsNeverReadOrWritten() {
        let control = Switch([7: true])
        let guardian = EnhancedUIGuard(control: control, ownPID: 7)
        guardian.willWrite(pid: 7)
        guardian.batchEnded(pid: 7)
        XCTAssertTrue(control.calls.isEmpty)
    }

    func testABatchWithoutWritesTouchesNothing() {
        let control = Switch([10: true])
        let guardian = EnhancedUIGuard(control: control, ownPID: 1)
        guardian.batchEnded(pid: 10)
        XCTAssertTrue(control.calls.isEmpty)
    }

    func testTheStateIsReadOncePerLifetimeAndAgainAfterIt() {
        let control = Switch([10: true])
        let clock = Clock()
        let guardian = EnhancedUIGuard(control: control, ownPID: 1, clock: { clock.now })
        for _ in 0..<3 {
            guardian.willWrite(pid: 10)
            guardian.batchEnded(pid: 10)
            clock.now += 0.2
        }
        XCTAssertEqual(control.calls.filter { $0.hasPrefix("read") }.count, 1)
        clock.now += EnhancedUIGuard.stateLifetime
        guardian.willWrite(pid: 10)
        guardian.batchEnded(pid: 10)
        XCTAssertEqual(control.calls.filter { $0.hasPrefix("read") }.count, 2)
    }

    func testAFailedRestoreIsOwedAndTheNextBatchRestoresItWithoutRereading() {
        let control = Switch([10: true])
        let clock = Clock()
        let guardian = EnhancedUIGuard(control: control, ownPID: 1, clock: { clock.now })
        control.refusingRestore = [10]
        guardian.willWrite(pid: 10)
        guardian.batchEnded(pid: 10)
        XCTAssertEqual(guardian.pendingRestores, [10])
        control.refusingRestore = []
        clock.now += EnhancedUIGuard.stateLifetime * 3
        guardian.willWrite(pid: 10)
        guardian.batchEnded(pid: 10)
        // The app may still be off because of Gio: its value is not re-read
        // (it would read false and never be put back).
        XCTAssertEqual(control.calls, ["read 10", "set 10 false", "set 10 true", "set 10 true"])
        XCTAssertEqual(control.value(10), true)
        XCTAssertTrue(guardian.pendingRestores.isEmpty)
    }

    func testAnOwedRestoreIsRetriedOnItsOwnAndForgettingTheAppDropsIt() {
        let control = Switch([10: true, 11: true])
        let guardian = EnhancedUIGuard(control: control, ownPID: 1)
        control.refusingRestore = [10, 11]
        for pid: pid_t in [10, 11] {
            guardian.willWrite(pid: pid)
            guardian.batchEnded(pid: pid)
        }
        control.refusingRestore = []
        guardian.restore(pid: 10)
        guardian.forget(pid: 11)
        XCTAssertEqual(guardian.pendingRestores, [])
        XCTAssertEqual(control.value(10), true)
    }

    func testAnAppSwitchedOffIsPendingUntilItsBatchEnds() {
        let control = Switch([10: true])
        let guardian = EnhancedUIGuard(control: control, ownPID: 1)
        guardian.willWrite(pid: 10)
        XCTAssertEqual(guardian.pendingRestores, [10])
        guardian.restore(pid: 10)
        XCTAssertEqual(guardian.pendingRestores, [])
        XCTAssertEqual(control.value(10), true)
        // A batch end after an explicit restore writes nothing more.
        guardian.batchEnded(pid: 10)
        XCTAssertEqual(control.calls, ["read 10", "set 10 false", "set 10 true"])
    }

    func testWithoutASwitchNothingHappens() {
        let guardian = EnhancedUIGuard(control: nil, ownPID: 1)
        guardian.willWrite(pid: 10)
        guardian.batchEnded(pid: 10)
        XCTAssertTrue(guardian.pendingRestores.isEmpty)
    }

    // MARK: Reconciler lanes

    private final class Actuator: WindowActuator, @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [WindowID: CGRect]
        let journal: Journal

        init(_ frames: [WindowID: CGRect], journal: Journal) {
            self.frames = frames
            self.journal = journal
        }

        func frame(of id: WindowID) throws -> CGRect? { lock.withLock { frames[id] } }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            try setFrame(frame, from: .zero, for: id, verify: true)
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            journal.append("write \(id.pid):\(id.elementID)")
            lock.withLock { frames[id] = frame }
        }

        func focus(id: WindowID) throws {}
    }

    private let here = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let there = CGRect(x: 500, y: 0, width: 400, height: 300)

    func testAReconcileLaneTurnsItOffAroundItsWritesAndAnAppItDoesNotWriteIsLeftAlone() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let b = WindowID(pid: 11, elementID: 1)
        let actuator = Actuator([a: here, b: there], journal: journal)
        let control = Switch([10: true, 11: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, enhancedUI: control, ownPID: 1)
        reconciler.reconcile(frames: [a: there, b: there], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(journal.lines, ["read 10", "set 10 false", "write 10:1", "set 10 true"])
    }

    func testConcurrentReconcileLanesRestoreEveryApp() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let b = WindowID(pid: 11, elementID: 1)
        let actuator = Actuator([a: here, b: here], journal: journal)
        let control = Switch([10: true, 11: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, enhancedUI: control, ownPID: 1)
        reconciler.reconcile(frames: [a: there, b: there], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(control.value(10), true)
        XCTAssertEqual(control.value(11), true)
        for pid in [10, 11] {
            let lines = journal.lines.filter { $0.contains(" \(pid)") || $0.hasPrefix("write \(pid):") }
            XCTAssertEqual(lines, ["read \(pid)", "set \(pid) false", "write \(pid):1", "set \(pid) true"])
        }
    }

    func testAMotionKeepsItOffUntilTheAppsFinalPassLane() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let actuator = Actuator([a: here], journal: journal)
        let control = Switch([10: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, enhancedUI: control, ownPID: 1)
        let middle = CGRect(x: 250, y: 0, width: 400, height: 300)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: a, from: here, to: middle)]))
        reconciler.waitForMotionIdle(timeout: 2)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: a, from: middle, to: there)]))
        reconciler.waitForMotionIdle(timeout: 2)
        // One switch for the whole flight, not one per frame.
        XCTAssertEqual(journal.lines, ["read 10", "set 10 false", "write 10:1", "write 10:1"])
        XCTAssertEqual(reconciler.pendingEnhancedUIRestores, [10])
        reconciler.reconcile(frames: [a: there], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(journal.lines.last, "set 10 true")
        XCTAssertTrue(reconciler.pendingEnhancedUIRestores.isEmpty)
    }

    func testTheSettleRestoresAMotionAppThatTheFinalPassDidNotVisit() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let actuator = Actuator([a: here], journal: journal)
        let control = Switch([10: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, enhancedUI: control, ownPID: 1)
        XCTAssertTrue(reconciler.submitMotion(pid: 10, writes: [MotionWrite(id: a, from: here, to: there)]))
        reconciler.waitForMotionIdle(timeout: 2)
        reconciler.restoreEnhancedUI(waiting: true)
        XCTAssertEqual(control.value(10), true)
        XCTAssertTrue(reconciler.pendingEnhancedUIRestores.isEmpty)
    }

    func testPrepositionAndNudgeWritesAreBatchesToo() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let actuator = Actuator([a: here], journal: journal)
        let control = Switch([10: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, enhancedUI: control, ownPID: 1)
        reconciler.preposition(frames: [a: there], from: [a: here])
        reconciler.nudge(steps: [a: [here, there]])
        XCTAssertEqual(control.value(10), true)
        XCTAssertEqual(journal.lines.filter { $0.hasPrefix("set") }, [
            "set 10 false", "set 10 true", "set 10 false", "set 10 true",
        ])
    }

    func testTheOwnPidIsNeverSwitchedEvenWhenItsWindowsAreWritten() {
        let journal = Journal()
        let own = WindowID(pid: 7, elementID: 1)
        let actuator = Actuator([own: here], journal: journal)
        let control = Switch([7: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, enhancedUI: control, ownPID: 7)
        reconciler.reconcile(frames: [own: there], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(journal.lines, ["write 7:1"])
    }

    func testOwedRestoresAreRetriedOnTheAppsLaneAtTheSettle() {
        let journal = Journal()
        let a = WindowID(pid: 10, elementID: 1)
        let actuator = Actuator([a: here], journal: journal)
        let control = Switch([10: true], journal: journal)
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial, enhancedUI: control, ownPID: 1)
        control.refusingRestore = [10]
        reconciler.reconcile(frames: [a: there], focused: nil, currentlyFocused: nil)
        XCTAssertEqual(control.value(10), false)
        XCTAssertEqual(reconciler.pendingEnhancedUIRestores, [10])
        control.refusingRestore = []
        reconciler.restoreEnhancedUI(waiting: true)
        XCTAssertEqual(control.value(10), true)
        XCTAssertTrue(reconciler.pendingEnhancedUIRestores.isEmpty)
    }
}
