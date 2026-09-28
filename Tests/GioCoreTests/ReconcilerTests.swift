import XCTest
@testable import GioCore

/// Plan §14: minimal writes, tolerance skips, vanished/failed recording,
/// focus last, deterministic order. The mock stands in for AX.
final class ReconcilerTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private final class MockActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var vanished: Set<WindowID> = []
        var failingFrames: Set<WindowID> = []
        var failingFocus: Set<WindowID> = []
        var sets: [(WindowID, CGRect)] = []
        var focuses: [WindowID] = []

        func frame(of id: WindowID) throws -> CGRect? {
            if failingFrames.contains(id) {
                throw MockError.unreadable
            }
            if vanished.contains(id) {
                return nil
            }
            return frames[id]
        }

        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            if failingFrames.contains(id) {
                throw MockError.unwritable
            }
            sets.append((id, frame))
            frames[id] = frame
        }

        func focus(id: WindowID) throws {
            if failingFocus.contains(id) {
                throw MockError.unfocusable
            }
            focuses.append(id)
        }
    }

    private enum MockError: Error {
        case unreadable
        case unwritable
        case unfocusable
    }

    func testSkipsAlreadyCorrectFrames() {
        let actuator = MockActuator()
        actuator.frames = [id(1): CGRect(x: 8, y: 8, width: 300, height: 784)]
        let reconciler = WindowReconciler(actuator: actuator)
        let report = reconciler.reconcile(
            frames: [id(1): CGRect(x: 8, y: 8, width: 300, height: 784)],
            focused: nil,
            currentlyFocused: nil
        )
        XCTAssertTrue(actuator.sets.isEmpty)
        XCTAssertEqual(report, ReconcileReport(alreadyCorrect: [id(1)]))
    }

    func testToleranceSkipsAndApplies() {
        let actuator = MockActuator()
        actuator.frames = [
            id(1): CGRect(x: 8.5, y: 8, width: 300, height: 784),
            id(2): CGRect(x: 8, y: 8, width: 300, height: 784),
        ]
        let reconciler = WindowReconciler(actuator: actuator)
        let report = reconciler.reconcile(
            frames: [
                id(1): CGRect(x: 8, y: 8, width: 300, height: 784),
                id(2): CGRect(x: 20, y: 8, width: 300, height: 784),
            ],
            focused: nil,
            currentlyFocused: nil
        )
        XCTAssertEqual(report.alreadyCorrect, [id(1)])
        XCTAssertEqual(report.applied, [id(2)])
        XCTAssertEqual(actuator.sets.count, 1)
    }

    func testVanishedAndFailedDoNotAbortBatch() {
        let actuator = MockActuator()
        actuator.frames = [id(3): CGRect(x: 0, y: 0, width: 10, height: 10)]
        actuator.vanished = [id(1)]
        actuator.failingFrames = [id(2)]
        let reconciler = WindowReconciler(actuator: actuator)
        let report = reconciler.reconcile(
            frames: [
                id(1): CGRect(x: 8, y: 8, width: 300, height: 784),
                id(2): CGRect(x: 8, y: 8, width: 300, height: 784),
                id(3): CGRect(x: 316, y: 8, width: 300, height: 784),
            ],
            focused: nil,
            currentlyFocused: nil
        )
        XCTAssertEqual(report.vanished, [id(1)])
        XCTAssertEqual(report.failed, [id(2)])
        XCTAssertEqual(report.applied, [id(3)])
    }

    func testFocusAppliedLastOnlyWhenChanged() {
        let actuator = MockActuator()
        let reconciler = WindowReconciler(actuator: actuator)
        let changed = reconciler.reconcile(
            frames: [:], focused: id(1), currentlyFocused: id(2)
        )
        XCTAssertEqual(actuator.focuses, [id(1)])
        XCTAssertEqual(changed, ReconcileReport(focusChanged: true))
        actuator.focuses = []
        let same = reconciler.reconcile(
            frames: [:], focused: id(1), currentlyFocused: id(1)
        )
        XCTAssertTrue(actuator.focuses.isEmpty)
        XCTAssertEqual(same, ReconcileReport())
        let none = reconciler.reconcile(frames: [:], focused: nil, currentlyFocused: id(1))
        XCTAssertTrue(actuator.focuses.isEmpty)
        XCTAssertEqual(none, ReconcileReport())
    }

    func testFocusFailureIsRecorded() {
        let actuator = MockActuator()
        actuator.failingFocus = [id(1)]
        let reconciler = WindowReconciler(actuator: actuator)
        let report = reconciler.reconcile(
            frames: [:], focused: id(1), currentlyFocused: nil
        )
        XCTAssertEqual(report, ReconcileReport(focusFailed: true))
    }

    func testFramesAppliedInSortedOrder() {
        let actuator = MockActuator()
        actuator.frames = [
            id(3): CGRect.zero,
            id(1): CGRect.zero,
            id(2): CGRect.zero,
        ]
        let reconciler = WindowReconciler(actuator: actuator)
        let frames = [
            id(3): CGRect(x: 624, y: 8, width: 300, height: 784),
            id(1): CGRect(x: 8, y: 8, width: 300, height: 784),
            id(2): CGRect(x: 316, y: 8, width: 300, height: 784),
        ]
        let report = reconciler.reconcile(
            frames: frames, focused: nil, currentlyFocused: nil
        )
        XCTAssertEqual(report.applied, [id(1), id(2), id(3)])
        XCTAssertEqual(actuator.sets.map(\.0), [id(1), id(2), id(3)])
    }
}
