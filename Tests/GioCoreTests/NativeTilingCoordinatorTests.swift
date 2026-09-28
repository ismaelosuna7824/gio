import Foundation
import XCTest
@testable import GioCore

private enum NativeMockError: Error { case failed }

private final class NativeMockBridge: WindowFrameBridge {
    typealias Handle = WindowID
    var frames: [WindowID: CGRect] = [:]
    var unsupported: Set<WindowID> = []
    var writes = 0
    var failWrites: Set<Int> = []
    func checkPermission() throws {}
    func capture(_ window: WindowID) throws -> (handle: WindowID, frame: CGRect) {
        guard let frame = frames[window] else { throw NativeMockError.failed }
        return (window, frame)
    }
    func frame(of handle: WindowID) throws -> CGRect { frames[handle]! }
    func canTile(_ handle: WindowID) throws -> Bool { !unsupported.contains(handle) }
    func apply(_ handle: WindowID, frame: CGRect) throws {
        writes += 1
        frames[handle] = frame
        if failWrites.contains(writes) { throw NativeMockError.failed }
    }
}

final class NativeTilingCoordinatorTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testSelectedCohortsAndOptInRestore() throws {
        let bridge = NativeMockBridge()
        let coordinator = NativeTilingCoordinator(bridge: bridge)
        try coordinator.registerDisplay("a", bounds: bounds)
        let original = CGRect(x: 10, y: 10, width: 20, height: 20)
        for id: WindowID in ["first", "second", "skip", "unselected"] { bridge.frames[id] = original }
        for id: WindowID in ["first", "second", "skip"] { try coordinator.adopt(id, on: "a") }
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
        for id: WindowID in ["a", "b"] {
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
        let connected = [DisplayID("b"): CGRect(x: 200, y: 0, width: 100, height: 100)]
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
