import Foundation
import XCTest
@testable import GioCore

private enum MockError: Error { case denied, failed }

private final class MockBridge: WorkspaceWindowBridge {
    typealias Handle = WindowID
    var frames: [WindowID: CGRect] = [:]
    var permitted = true
    var failFrameFor: Set<WindowID> = []
    var failCalls: Set<Int> = []
    var mutateThenFailCalls: Set<Int> = []
    var calls = 0
    func checkPermission() throws { if !permitted { throw MockError.denied } }
    func capture(_ window: WindowID) throws -> (handle: WindowID, frame: CGRect) {
        guard let frame = frames[window] else { throw MockError.failed }
        return (window, frame)
    }
    func frame(of handle: WindowID) throws -> CGRect {
        if failFrameFor.contains(handle) { throw MockError.failed }
        return frames[handle]!
    }
    func move(_ handle: WindowID, to origin: CGPoint) throws {
        calls += 1
        if failCalls.contains(calls) { throw MockError.failed }
        frames[handle]!.origin = origin
        if mutateThenFailCalls.contains(calls) { throw MockError.failed }
    }
}

final class WorkspaceCoordinatorTests: XCTestCase {
    private func setup() throws -> (WorkspaceCoordinator<MockBridge>, MockBridge) {
        let bridge = MockBridge()
        let coordinator = WorkspaceCoordinator(bridge: bridge)
        try coordinator.addDisplay("a", rect: CGRect(x: 0, y: 0, width: 100, height: 100), initialWorkspace: "one")
        try coordinator.addWorkspace("two", on: "a")
        return (coordinator, bridge)
    }

    func testSwitchRestoresAndDisconnectRestoresBeforeRelease() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: -19, y: 99))
        try coordinator.switchTo("two", on: "a")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        try coordinator.switchTo("one", on: "a")
        try coordinator.removeDisplay("a")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertThrowsError(try coordinator.model.membership(of: "w"))
    }

    func testPartialFailureRollsBackWithoutCommittingAndReportsRollbackFailure() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["a", "b"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "one", on: "a")
        }
        bridge.failCalls = [2]
        XCTAssertThrowsError(try coordinator.switchTo("two", on: "a"))
        XCTAssertEqual(try coordinator.model.activeWorkspace(on: "a"), "one")
        XCTAssertEqual(bridge.frames["a"]!.origin, CGPoint(x: 10, y: 10))
        bridge.failCalls = [bridge.calls + 2, bridge.calls + 4]
        XCTAssertThrowsError(try coordinator.switchTo("two", on: "a")) { error in
            guard case WorkspaceCoordinatorError.operationFailed(_, let failures) = error else {
                return XCTFail("Expected rollback evidence")
            }
            XCTAssertEqual(failures.count, 1)
        }
        XCTAssertEqual(try coordinator.model.activeWorkspace(on: "a"), "one")
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertEqual(bridge.frames["a"]!.origin, CGPoint(x: -19, y: 99))
        XCTAssertThrowsError(try coordinator.switchTo("two", on: "a")) { error in
            guard case WorkspaceCoordinatorError.recoveryRequired = error else {
                return XCTFail("Expected recovery gate")
            }
        }
        XCTAssertThrowsError(try coordinator.removeWindow("a"))
        XCTAssertThrowsError(try coordinator.addWorkspace("three", on: "a"))
        try coordinator.shutdown()
        XCTAssertFalse(coordinator.recoveryRequired)
        XCTAssertEqual(bridge.frames["a"]!.origin, CGPoint(x: 10, y: 10))
    }

    func testRecoveryShutdownFailureRetainsGateUntilSuccessfulRetry() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "one", on: "a")
        bridge.mutateThenFailCalls = [1]
        bridge.failCalls = [2]
        XCTAssertThrowsError(try coordinator.switchTo("two", on: "a"))
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: -19, y: 99))
        bridge.failCalls = [bridge.calls + 1]
        XCTAssertThrowsError(try coordinator.shutdown())
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
        bridge.failCalls = []
        try coordinator.shutdown()
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertFalse(coordinator.recoveryRequired)
    }

    func testCrossDisplayVisibleTransferMovesAndShutdownRestores() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "one", on: "a")
        try coordinator.reassign("w", to: "one", on: "b")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 201, y: 1))
        try coordinator.shutdown()
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertThrowsError(try coordinator.model.membership(of: "w"))
    }

    func testStraddlingVisibleTransferRelocatesIntoDestination() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 100, y: 0, width: 100, height: 100), initialWorkspace: "one")
        bridge.frames["w"] = CGRect(x: 90, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "one", on: "a")
        try coordinator.reassign("w", to: "one", on: "b")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 101, y: 1))
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "b")
    }

    func testHiddenRemovalRestoresInitialFrameBeforeReleasingOwnership() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        try coordinator.removeWindow("w")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertThrowsError(try coordinator.model.membership(of: "w"))
    }

    func testShutdownWithoutOwnedWindowsNeedsNoPermissionButOwnedWindowStillDoes() throws {
        let (empty, emptyBridge) = try setup()
        emptyBridge.permitted = false
        try empty.shutdown()
        XCTAssertThrowsError(try empty.model.activeWorkspace(on: "a"))
        XCTAssertEqual(emptyBridge.calls, 0)

        let (owned, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try owned.assign("w", to: "two", on: "a")
        let parked = bridge.frames["w"]!.origin
        let moves = bridge.calls
        bridge.permitted = false
        XCTAssertThrowsError(try owned.shutdown()) { error in
            guard case MockError.denied = error else { return XCTFail("Expected permission denial") }
        }
        XCTAssertEqual(bridge.calls, moves)
        XCTAssertEqual(bridge.frames["w"]!.origin, parked)
        XCTAssertEqual(try owned.model.membership(of: "w").display, "a")
        bridge.permitted = true
        try owned.shutdown()
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
    }

    func testProvenClosedForgetDoesNotAccessAXButLiveRemovalRestores() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["closed", "live"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "two", on: "a")
        }
        let before = bridge.calls
        bridge.permitted = false
        try coordinator.forgetClosedWindow("closed")
        XCTAssertEqual(bridge.calls, before)
        XCTAssertThrowsError(try coordinator.model.membership(of: "closed"))
        XCTAssertThrowsError(try coordinator.removeWindow("live"))
        bridge.permitted = true
        try coordinator.removeWindow("live")
        XCTAssertEqual(bridge.frames["live"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(bridge.calls, before + 1)
    }

    func testParkedCrossDisplayReassignmentRelocatesParking() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        try coordinator.addWorkspace("two", on: "b")
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        try coordinator.reassign("w", to: "two", on: "b")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 181, y: 99))
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "b")
        try coordinator.switchTo("two", on: "b")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 201, y: 1))
    }

    func testUnsafeCornersDoNotMoveWindowOrCommit() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("left", rect: CGRect(x: -100, y: 90, width: 100, height: 100), initialWorkspace: "one")
        try coordinator.addDisplay("right", rect: CGRect(x: 99, y: 90, width: 100, height: 100), initialWorkspace: "one")
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertThrowsError(try coordinator.assign("w", to: "two", on: "a"))
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 10, y: 10))
        XCTAssertThrowsError(try coordinator.model.membership(of: "w"))
    }

    func testDisconnectedOwnerRestoresMultipleWindowsOntoConnectedDisplay() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        for id: WindowID in ["first", "second"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "two", on: "a")
        }
        try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)])
        XCTAssertEqual(bridge.frames["first"]!.origin, CGPoint(x: 200, y: 0))
        XCTAssertEqual(bridge.frames["second"]!.origin, CGPoint(x: 220, y: 0))
    }

    func testOversizedWindowCannotBeRestoredAndOwnershipRemains() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["large"] = CGRect(x: 0, y: 0, width: 80, height: 80)
        try coordinator.assign("large", to: "one", on: "a")
        let before = bridge.calls
        XCTAssertThrowsError(try coordinator.shutdown(connectedDisplays: ["small": CGRect(x: 200, y: 0, width: 40, height: 40)])) { error in
            guard case WorkspaceCoordinatorError.noSafeRestorePosition("large") = error else {
                return XCTFail("Expected explicit unsafe restore error")
            }
        }
        XCTAssertEqual(bridge.calls, before)
        XCTAssertEqual(try coordinator.model.membership(of: "large").display, "a")
    }

    func testResizedWindowUsesCurrentSizeForRestoreLayout() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["first", "second"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "two", on: "a")
        }
        bridge.frames["first"]!.size = CGSize(width: 70, height: 30)
        bridge.frames["second"]!.size = CGSize(width: 50, height: 30)
        try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)])
        XCTAssertEqual(bridge.frames["first"]!.origin, CGPoint(x: 200, y: 0))
        XCTAssertEqual(bridge.frames["second"]!.origin, CGPoint(x: 200, y: 30))
    }

    func testResizedOversizeAndFrameReadFailureVetoQuitWithoutMoves() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        let before = bridge.calls
        bridge.failFrameFor = ["w"]
        XCTAssertThrowsError(try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)]))
        bridge.failFrameFor = []
        bridge.frames["w"]!.size = CGSize(width: 101, height: 20)
        XCTAssertThrowsError(try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)])) { error in
            guard case WorkspaceCoordinatorError.noSafeRestorePosition("w") = error else {
                return XCTFail("Expected oversized-window rejection")
            }
        }
        XCTAssertEqual(bridge.calls, before)
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
    }

    func testDisconnectedRestoreFailureRetainsOwnershipAndBlocksExit() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        bridge.failCalls = [bridge.calls + 1]
        XCTAssertThrowsError(try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)]))
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
    }

    func testPermissionAndDisconnectFailurePreserveOwnership() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        bridge.permitted = false
        XCTAssertThrowsError(try coordinator.assign("w", to: "one", on: "a"))
        bridge.permitted = true
        try coordinator.assign("w", to: "two", on: "a")
        bridge.failCalls = [bridge.calls + 1]
        XCTAssertThrowsError(try coordinator.removeDisplay("a"))
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
    }
}
