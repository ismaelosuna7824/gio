import XCTest
@testable import GioCore

/// HD-02: workspace-switch prepositions are reconciler writes: lane-planned,
/// lean (known origin, no verify, no reads), never focus, nothing else written.
final class PrepositionTests: XCTestCase {
    private func id(_ pid: pid_t, _ element: UInt64) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private final class Recorder: WindowActuator {
        private let lock = NSLock()
        private(set) var lean: [(WindowID, CGRect, CGRect, Bool)] = []
        private(set) var plain: [WindowID] = []
        private(set) var reads = 0
        private(set) var focuses = 0
        var failing: Set<WindowID> = []

        func frame(of id: WindowID) throws -> CGRect? {
            lock.withLock { reads += 1 }
            return nil
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            lock.withLock { plain.append(id) }
        }

        func setFrame(_ frame: CGRect, from current: CGRect, for id: WindowID, verify: Bool) throws {
            if failing.contains(id) {
                throw NSError(domain: "mock", code: 1)
            }
            lock.withLock { lean.append((id, frame, current, verify)) }
        }

        func focus(id: WindowID) throws {
            lock.withLock { focuses += 1 }
        }
    }

    private let below = CGRect(x: 0, y: 900, width: 400, height: 800)
    private let origin = CGRect(x: 0, y: -2000, width: 400, height: 800)

    func testWritesLeanUnverifiedFramesFromTheKnownOrigin() {
        let actuator = Recorder()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let written = reconciler.preposition(
            frames: [id(1, 1): below, id(2, 1): below.offsetBy(dx: 10, dy: 0)],
            from: [id(1, 1): origin, id(2, 1): origin]
        )
        XCTAssertEqual(written, [id(1, 1), id(2, 1)])
        XCTAssertEqual(actuator.lean.map(\.0), [id(1, 1), id(2, 1)])
        XCTAssertEqual(actuator.lean.map(\.1), [below, below.offsetBy(dx: 10, dy: 0)])
        XCTAssertEqual(actuator.lean.map(\.2), [origin, origin])
        XCTAssertEqual(actuator.lean.map(\.3), [false, false])
    }

    func testNothingElseIsWrittenReadOrFocused() {
        let actuator = Recorder()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        reconciler.preposition(frames: [id(1, 1): below], from: [id(1, 1): origin])
        XCTAssertTrue(actuator.plain.isEmpty)
        XCTAssertEqual(actuator.reads, 0)
        XCTAssertEqual(actuator.focuses, 0)
    }

    func testWindowsWithoutAKnownOriginAreSkipped() {
        let actuator = Recorder()
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let written = reconciler.preposition(frames: [id(1, 1): below, id(1, 2): below], from: [id(1, 1): origin])
        XCTAssertEqual(written, [id(1, 1)])
        XCTAssertEqual(actuator.lean.count, 1)
    }

    func testFailedWriteIsNotReportedAsWritten() {
        let actuator = Recorder()
        actuator.failing = [id(1, 1)]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let written = reconciler.preposition(
            frames: [id(1, 1): below, id(1, 2): below], from: [id(1, 1): origin, id(1, 2): origin]
        )
        XCTAssertEqual(written, [id(1, 2)])
    }

    func testConcurrentLanesWriteEveryApp() {
        let actuator = Recorder()
        let reconciler = WindowReconciler(actuator: actuator)
        let written = reconciler.preposition(
            frames: [id(1, 1): below, id(2, 1): below, id(3, 1): below],
            from: [id(1, 1): origin, id(2, 1): origin, id(3, 1): origin]
        )
        XCTAssertEqual(Set(written), [id(1, 1), id(2, 1), id(3, 1)])
        XCTAssertEqual(written, written.sorted())
    }
}
