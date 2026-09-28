import Foundation
import XCTest
@testable import GioCore

private enum NativeMockError: Error { case failed }
private struct MockMismatch: WindowFrameMismatch {
    let mismatchedFrames: (requested: CGRect, actual: CGRect)?
}

private final class NativeMockBridge: WindowFrameBridge {
    typealias Handle = LegacyWindowID
    var frames: [LegacyWindowID: CGRect] = [:]
    var unsupported: Set<LegacyWindowID> = []
    var writes = 0
    var failWrites: Set<Int> = []
    var constrained: Set<LegacyWindowID> = []
    var clampWidth: CGFloat = 60
    var clampUpTo: CGFloat = 99
    var impreciseRollback = false
    var attempts: [LegacyWindowID] = []
    var failReads: Set<Int> = []
    var reads = 0
    func checkPermission() throws {}
    func capture(_ window: LegacyWindowID) throws -> (handle: LegacyWindowID, frame: CGRect) {
        guard let frame = frames[window] else { throw NativeMockError.failed }
        return (window, frame)
    }
    func frame(of handle: LegacyWindowID) throws -> CGRect {
        reads += 1
        if failReads.contains(reads) { throw NativeMockError.failed }
        return frames[handle]!
    }
    func canTile(_ handle: LegacyWindowID) throws -> Bool { !unsupported.contains(handle) }
    func apply(_ handle: LegacyWindowID, frame: CGRect) throws {
        writes += 1
        attempts.append(handle)
        if constrained.contains(handle), frame.width <= clampUpTo, frame.width > 20 {
            let actual = CGRect(x: frame.minX, y: frame.minY, width: frame.width + clampWidth, height: frame.height)
            frames[handle] = actual
            throw MockMismatch(mismatchedFrames: (frame, actual))
        }
        frames[handle] = impreciseRollback && frame.width == 20
            ? frame.offsetBy(dx: 1, dy: 0) : frame
        if failWrites.contains(writes) { throw NativeMockError.failed }
    }
}

final class NativeTilingCoordinatorTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testConstraintSkipsOnlyFailedWindowAndRestoresOnlyTiled() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["a", "b", "outside"] { bridge.frames[id] = original }
        for id: LegacyWindowID in ["a", "b"] { try coordinator.adopt(id, on: "a") }
        bridge.constrained = ["a"]
        XCTAssertEqual(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds), ["a"])
        XCTAssertEqual(bridge.frames["a"], original)
        XCTAssertEqual(bridge.frames["b"], bounds)
        XCTAssertEqual(bridge.frames["outside"], original)
        let writes = bridge.writes
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.writes, writes + 1)
        XCTAssertEqual(bridge.frames["b"], original)
    }

    func testImpreciseRollbackBlocksRetryAndRetainsShutdownOwnership() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["a", "b"] { bridge.frames[id] = original; try coordinator.adopt(id, on: "a") }
        bridge.constrained = ["a"]
        bridge.impreciseRollback = true
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(_, let failures) = $0 else { return XCTFail() }
            guard let failure = failures.first as? NativeTilingError,
                  case .rollbackFrameMismatch(let id, let expected, let actual) = failure else {
                return XCTFail("Expected exact rollback mismatch")
            }
            XCTAssertEqual(id, "a")
            XCTAssertEqual(expected, original)
            XCTAssertEqual(actual, original.offsetBy(dx: 1, dy: 0))
        }
        XCTAssertEqual(bridge.attempts, ["a", "a"])
        XCTAssertTrue(coordinator.recoveryRequired)
        bridge.impreciseRollback = false
        try coordinator.shutdown(connectedDisplays: ["a": bounds])
        XCTAssertEqual(bridge.frames["a"], original)
        XCTAssertEqual(bridge.writes, 3)
    }

    func testRollbackReadFailureBlocksRetryAndRetainsShutdownOwnership() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["a", "b"] { bridge.frames[id] = original; try coordinator.adopt(id, on: "a") }
        bridge.constrained = ["a"]
        bridge.failReads = [bridge.reads + 2]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(_, let failures) = $0 else { return XCTFail() }
            guard let failure = failures.first as? NativeTilingError,
                  case .rollbackFrameReadFailed(let id, _) = failure else {
                return XCTFail("Expected rollback read failure")
            }
            XCTAssertEqual(id, "a")
        }
        XCTAssertEqual(bridge.attempts, ["a", "a"])
        XCTAssertTrue(coordinator.recoveryRequired)
        bridge.failReads = []
        try coordinator.shutdown(connectedDisplays: ["a": bounds])
        XCTAssertEqual(bridge.writes, 3)
    }

    func testUnsupportedSkipsDoNotConsumeConstraintRetryBudget() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        for id: LegacyWindowID in ["a", "b", "u1", "u2", "u3", "u4"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.adopt(id, on: "a")
        }
        bridge.unsupported = ["u1", "u2", "u3", "u4"]
        bridge.constrained = ["a"]
        XCTAssertEqual(Set(try coordinator.reflow(on: "a", selected: Set(bridge.frames.keys), usableBounds: bounds)),
                       ["a", "u1", "u2", "u3", "u4"])
        XCTAssertEqual(bridge.frames["b"], bounds)
    }

    func testLaterReadFailureIsNotMaskedByInitialConstraint() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        for id: LegacyWindowID in ["a", "b"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.adopt(id, on: "a")
        }
        bridge.constrained = ["a"]
        // First attempt reads a; rollback verification reads a; retry then fails its read.
        bridge.failReads = [bridge.reads + 3]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(let cause, let failures) = $0 else { return XCTFail() }
            XCTAssertTrue(cause is NativeMockError)
            XCTAssertTrue(failures.isEmpty)
        }
        XCTAssertEqual(bridge.frames["a"], CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testClassifierRejectsPositionShrinkAndInvalidGeometry() {
        let frame = CGRect(x: 8, y: 47, width: 440, height: 553)
        XCTAssertTrue(ConstrainedFrame.isPlausible(requested: frame, actual: CGRect(x: 8, y: 47, width: 500, height: 553)))
        XCTAssertFalse(ConstrainedFrame.isPlausible(requested: frame, actual: CGRect(x: 10, y: 47, width: 500, height: 553)))
        XCTAssertFalse(ConstrainedFrame.isPlausible(requested: frame, actual: CGRect(x: 8, y: 47, width: 500, height: 550)))
        XCTAssertFalse(ConstrainedFrame.isPlausible(requested: frame, actual: CGRect(x: 8, y: 47, width: CGFloat.infinity, height: 553)))
        let huge = CGFloat.greatestFiniteMagnitude
        XCTAssertFalse(ConstrainedFrame.isPlausible(requested: CGRect(x: huge, y: 0, width: huge, height: 20),
                                                    actual: CGRect(x: huge, y: 0, width: huge, height: 30)))
        XCTAssertTrue(ConstrainedFrame.isPlausible(requested: CGRect(x: -200, y: -100, width: 40, height: 50),
                                                   actual: CGRect(x: -200, y: -100, width: 60, height: 50)))
    }

    func testSelectedPreviouslyTiledWindowPreventsRetry() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["a", "b"] { bridge.frames[id] = original; try coordinator.adopt(id, on: "a") }
        try coordinator.reflow(on: "a", selected: ["a"], usableBounds: bounds)
        bridge.constrained = ["b"]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds))
        XCTAssertEqual(bridge.frames["a"], bounds)
        XCTAssertEqual(bridge.frames["b"], original)
    }

    func testRepeatedConstraintsAreBoundedAndOriginalErrorRetained() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        for id: LegacyWindowID in ["a", "b", "c", "d", "e"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.adopt(id, on: "a")
        }
        bridge.constrained = ["a", "b", "c", "d", "e"]
        bridge.clampUpTo = 100
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: bridge.constrained, usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(let cause, let failures) = $0 else { return XCTFail() }
            XCTAssertTrue(cause is MockMismatch)
            XCTAssertTrue(failures.isEmpty)
        }
        XCTAssertLessThanOrEqual(bridge.writes, 20)
    }

    func testRollbackFailureNeverRetriesConstraint() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        for id: LegacyWindowID in ["a", "b"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.adopt(id, on: "a")
        }
        bridge.constrained = ["a"]
        bridge.failWrites = [2]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(_, let failures) = $0 else { return XCTFail() }
            XCTAssertEqual(failures.count, 1)
        }
        XCTAssertTrue(coordinator.recoveryRequired)
    }

    func testSelectedCohortsAndOptInRestore() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["first", "second", "skip", "unselected"] { bridge.frames[id] = original }
        for id: LegacyWindowID in ["first", "second", "skip"] { try coordinator.adopt(id, on: "a") }
        bridge.unsupported = ["skip"]
        XCTAssertEqual(try coordinator.reflow(on: "a", selected: ["first", "skip"], usableBounds: bounds), ["skip"])
        XCTAssertEqual(bridge.frames["first"], bounds)
        XCTAssertEqual(bridge.frames["second"], original)
        XCTAssertEqual(bridge.frames["unselected"], original)
        XCTAssertEqual(try coordinator.reflow(on: "a", selected: ["second"], usableBounds: bounds), [])
        XCTAssertEqual(bridge.frames["first"], bounds) // Space change does not move inactive windows.
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["first"], original)
        XCTAssertEqual(bridge.frames["second"], original)
    }

    func testMutatingFailureRollsBackIncludingFailedWriteAndPreservesPreTile() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: LegacyWindowID in ["a", "b"] {
            bridge.frames[id] = original
            try coordinator.adopt(id, on: "a")
        }
        bridge.failWrites = [2]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["a", "b"], usableBounds: bounds)) {
            guard case NativeTilingError.operationFailed(let underlying, let failures) = $0 else {
                return XCTFail("Expected operation failure")
            }
            XCTAssertTrue(underlying is NativeMockError)
            XCTAssertTrue(failures.isEmpty)
        }
        XCTAssertEqual(bridge.frames["a"], original)
        XCTAssertEqual(bridge.frames["b"], original)
        bridge.failWrites = []
        try coordinator.reflow(on: "a", selected: ["a"], usableBounds: bounds)
        bridge.failWrites = [bridge.writes + 1]
        XCTAssertThrowsError(try coordinator.restoreTiledFrames(on: "a"))
        bridge.failWrites = []
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["a"], original)
    }

    func testRollbackFailureGatesReflowButShutdownCanRecover() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.adopt("w", on: "a")
        bridge.failWrites = [1, 2]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["w"], usableBounds: bounds))
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertThrowsError(try coordinator.reflow(on: "a", selected: ["w"], usableBounds: bounds))
        bridge.failWrites = []
        try coordinator.shutdown(connectedDisplays: ["a": bounds])
        XCTAssertFalse(coordinator.recoveryRequired)
        XCTAssertEqual(bridge.frames["w"], CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testShutdownRestoresInactiveOwnedWithDisconnectedFallback() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        try coordinator.registerDisplay("b", bounds: CGRect(x: 200, y: 0, width: 100, height: 100))
        bridge.frames["inactive"] = CGRect(x: 10, y: 0, width: 50, height: 50)
        bridge.frames["connected"] = CGRect(x: 200, y: 0, width: 50, height: 100)
        try coordinator.adopt("inactive", on: "a")
        try coordinator.adopt("connected", on: "b")
        try coordinator.reflow(on: "a", selected: ["inactive"], usableBounds: bounds)
        let connected = [LegacyDisplayID("b"): CGRect(x: 200, y: 0, width: 100, height: 100)]
        // Registered A bounds remain cached, but only the fresh B snapshot may authorize Quit.
        try coordinator.shutdown(connectedDisplays: connected)
        XCTAssertEqual(bridge.frames["inactive"], CGRect(x: 200, y: 0, width: 50, height: 50))
        XCTAssertEqual(bridge.frames["connected"], CGRect(x: 200, y: 0, width: 50, height: 100))
        XCTAssertEqual(bridge.writes, 2) // One tile and one fallback; untouched connected is never written.
    }

    func testDisplaySpecificRestoreAndReadoptionPreserveOriginal() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let other = CGRect(x: 200, y: 0, width: 100, height: 100)
        try coordinator.registerDisplay("b", bounds: other)
        let originalA = CGRect(x: 10, y: 10, width: 20, height: 20)
        let originalB = CGRect(x: 210, y: 10, width: 20, height: 20)
        bridge.frames["moving"] = originalA
        bridge.frames["b"] = originalB
        try coordinator.adopt("moving", on: "a")
        try coordinator.adopt("b", on: "b")
        try coordinator.reflow(on: "a", selected: ["moving"], usableBounds: bounds)
        try coordinator.reflow(on: "b", selected: ["b"], usableBounds: other)
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["moving"], originalA)
        XCTAssertEqual(bridge.frames["b"], other)
        try coordinator.adopt("moving", on: "a")
        try coordinator.reflow(on: "a", selected: ["moving"], usableBounds: bounds)
        try coordinator.adopt("moving", on: "b")
        try coordinator.adopt("moving", on: "b")
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["moving"], bounds)
        try coordinator.restoreTiledFrames(on: "b")
        XCTAssertEqual(bridge.frames["moving"], originalA)
        XCTAssertEqual(bridge.frames["b"], originalB)
    }

    func testDisableReenableRecapturesManualFrameForQuit() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let first = CGRect(x: 10, y: 10, width: 20, height: 20)
        let manual = CGRect(x: 25, y: 30, width: 35, height: 40)
        bridge.frames["w"] = first
        try coordinator.adopt("w", on: "a")
        try coordinator.reflow(on: "a", selected: ["w"], usableBounds: bounds)
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["w"], first)
        bridge.frames["w"] = manual
        try coordinator.adopt("w", on: "a")
        try coordinator.reflow(on: "a", selected: ["w"], usableBounds: bounds)
        try coordinator.shutdown(connectedDisplays: ["a": bounds])
        XCTAssertEqual(bridge.frames["w"], manual)
    }

    func testLargeOriginalRestoresExactlyAfterMinSizeClamp() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        bridge.frames["w"] = original
        try coordinator.adopt("w", on: "a")
        bridge.constrained = ["w"]
        bridge.clampUpTo = 100
        // The tiled target is narrow enough to hit the mock min-size clamp,
        // so the forward write fails and the coordinator rolls back.
        XCTAssertEqual(try coordinator.reflow(on: "a", selected: ["w"], usableBounds: bounds), ["w"])
        XCTAssertEqual(bridge.frames["w"], original)
    }

    func testUntouchedManualMoveIsNeverRestoredOnQuit() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let initial = CGRect(x: 10, y: 10, width: 20, height: 20)
        let manual = CGRect(x: 30, y: 30, width: 20, height: 20)
        bridge.frames["untouched"] = initial
        try coordinator.adopt("untouched", on: "a")
        bridge.unsupported = ["untouched"]
        XCTAssertEqual(try coordinator.reflow(on: "a", selected: ["untouched"], usableBounds: bounds), ["untouched"])
        bridge.frames["untouched"] = manual
        try coordinator.shutdown(connectedDisplays: [:])
        XCTAssertEqual(bridge.frames["untouched"], manual)
        XCTAssertEqual(bridge.writes, 0)
    }
}
