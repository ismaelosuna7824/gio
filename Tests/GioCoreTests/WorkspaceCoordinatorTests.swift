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
    var frameCalls = 0
    var failApplyCalls: Set<Int> = []
    var mutateThenFailApplyCalls: Set<Int> = []
    var unsupported: Set<WindowID> = []
    func canTile(_ handle: WindowID) throws -> Bool { !unsupported.contains(handle) }
    func apply(_ handle: WindowID, frame: CGRect) throws {
        frameCalls += 1
        if failApplyCalls.contains(frameCalls) { throw MockError.failed }
        frames[handle] = frame
        if mutateThenFailApplyCalls.contains(frameCalls) { throw MockError.failed }
    }
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

    func testReflowSkipsUnsupportedAndOtherDisplaysAndRestoresFrames() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        for id: WindowID in ["a", "z", "skip", "other", "hidden"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 25)
        }
        try coordinator.assign("z", to: "one", on: "a")
        try coordinator.assign("a", to: "one", on: "a")
        try coordinator.assign("skip", to: "one", on: "a")
        try coordinator.assign("other", to: "one", on: "b")
        try coordinator.assign("hidden", to: "two", on: "a")
        bridge.unsupported = ["skip"]
        let skipped = try coordinator.reflow(on: "a", usableBounds: CGRect(x: 5, y: 5, width: 90, height: 90))
        XCTAssertEqual(skipped, ["skip"])
        XCTAssertEqual(bridge.frames["a"], CGRect(x: 5, y: 5, width: 45, height: 90))
        XCTAssertEqual(bridge.frames["z"], CGRect(x: 50, y: 5, width: 45, height: 90))
        XCTAssertEqual(bridge.frames["skip"]!.size, CGSize(width: 20, height: 25))
        XCTAssertEqual(bridge.frames["other"]!.size, CGSize(width: 20, height: 25))
        let userFrame = CGRect(x: 30, y: 35, width: 33, height: 28)
        bridge.frames["skip"] = userFrame
        let applyCount = bridge.frameCalls
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frameCalls, applyCount + 2)
        XCTAssertEqual(bridge.frames["skip"], userFrame)
        XCTAssertEqual(bridge.frames["a"], CGRect(x: 10, y: 10, width: 20, height: 25))
        XCTAssertEqual(try coordinator.model.membership(of: "a").workspace, "one")
    }

    func testDisconnectedFallbackAvoidsConnectedOriginalAndRejectsWhenFull() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        bridge.frames["a-detached"] = CGRect(x: 10, y: 10, width: 50, height: 50)
        bridge.frames["z-connected"] = CGRect(x: 200, y: 0, width: 50, height: 100)
        try coordinator.assign("a-detached", to: "one", on: "a")
        try coordinator.assign("z-connected", to: "one", on: "b")
        let connected = [DisplayID("b"): CGRect(x: 200, y: 0, width: 100, height: 100)]
        try coordinator.shutdown(connectedDisplays: connected)
        XCTAssertEqual(bridge.frames["a-detached"], CGRect(x: 250, y: 0, width: 50, height: 50))
        XCTAssertEqual(bridge.frames["z-connected"], CGRect(x: 200, y: 0, width: 50, height: 100))

        let (full, fullBridge) = try setup()
        try full.addDisplay("b", rect: connected["b"]!, initialWorkspace: "one")
        fullBridge.frames["a-detached"] = CGRect(x: 10, y: 10, width: 50, height: 50)
        fullBridge.frames["z-connected"] = connected["b"]!
        try full.assign("a-detached", to: "one", on: "a")
        try full.assign("z-connected", to: "one", on: "b")
        XCTAssertThrowsError(try full.shutdown(connectedDisplays: connected))
        XCTAssertEqual(fullBridge.frameCalls, 0)
        XCTAssertEqual(try full.model.membership(of: "a-detached").display, "a")
    }

    func testTiledParkingUsesCurrentSizeAndHiddenDisableRestoresOnShow() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("left", rect: CGRect(x: -40, y: 0, width: 40, height: 100), initialWorkspace: "one")
        let original = CGRect(x: 12, y: 13, width: 20, height: 20)
        bridge.frames["w"] = original
        try coordinator.assign("w", to: "one", on: "a")
        let beforeTile = CGRect(x: 27, y: 28, width: 24, height: 26)
        bridge.frames["w"] = beforeTile
        try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 80, height: 80))
        try coordinator.switchTo("two", on: "a")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 99, y: 99))
        try coordinator.restoreTiledFrames(on: "a")
        XCTAssertEqual(bridge.frames["w"]!.size, beforeTile.size)
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 99, y: 99))
        XCTAssertEqual(try coordinator.model.membership(of: "w").workspace, "one")
        try coordinator.switchTo("one", on: "a")
        XCTAssertEqual(bridge.frames["w"], beforeTile)
    }

    func testTiledParkingCannotOverlapNeighborAndDoesNotCommitSwitch() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("left", rect: CGRect(x: -100, y: 90, width: 100, height: 100), initialWorkspace: "one")
        try coordinator.addDisplay("right", rect: CGRect(x: 99, y: 90, width: 100, height: 100), initialWorkspace: "one")
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "one", on: "a")
        try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 80, height: 80))
        let tiled = bridge.frames["w"]!
        XCTAssertThrowsError(try coordinator.switchTo("two", on: "a"))
        XCTAssertEqual(bridge.frames["w"], tiled)
        XCTAssertEqual(try coordinator.model.activeWorkspace(on: "a"), "one")
    }

    func testParkedCrossDisplayTransferUsesCurrentSize() throws {
        let (coordinator, bridge) = try setup()
        try coordinator.addDisplay("b", rect: CGRect(x: 200, y: 0, width: 100, height: 100), initialWorkspace: "one")
        try coordinator.addWorkspace("two", on: "b")
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        bridge.frames["w"]!.size = CGSize(width: 80, height: 40)
        try coordinator.reassign("w", to: "two", on: "b")
        XCTAssertEqual(bridge.frames["w"]!.origin, CGPoint(x: 121, y: 99))
    }

    func testMixedHideAndFullFrameShowFailureRollsBackBothWindows() throws {
        for failRollback in [false, true] {
            let (coordinator, bridge) = try setup()
            bridge.frames["show"] = CGRect(x: 13, y: 14, width: 20, height: 21)
            try coordinator.assign("show", to: "one", on: "a")
            try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 80, height: 80))
            try coordinator.switchTo("two", on: "a")
            try coordinator.restoreTiledFrames(on: "a")
            bridge.frames["hide"] = CGRect(x: 40, y: 42, width: 22, height: 23)
            try coordinator.assign("hide", to: "two", on: "a")
            let before = bridge.frames
            let applyBefore = bridge.frameCalls
            bridge.mutateThenFailApplyCalls = [applyBefore + 1]
            if failRollback { bridge.failApplyCalls = [applyBefore + 3] }
            XCTAssertThrowsError(try coordinator.switchTo("one", on: "a")) { error in
                guard case WorkspaceCoordinatorError.operationFailed(_, let failures) = error else {
                    return XCTFail("Expected transactional failure")
                }
                XCTAssertEqual(failures.count, failRollback ? 1 : 0)
            }
            if failRollback {
                XCTAssertNotEqual(bridge.frames["hide"], before["hide"])
            } else {
                XCTAssertEqual(bridge.frames["hide"], before["hide"])
            }
            XCTAssertEqual(bridge.frames["show"], before["show"])
            XCTAssertEqual(try coordinator.model.activeWorkspace(on: "a"), "two")
            XCTAssertEqual(coordinator.recoveryRequired, failRollback)
        }
    }

    func testHiddenDisableRollbackRestoresWholeTiledFrames() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["a", "b"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "one", on: "a")
        }
        try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try coordinator.switchTo("two", on: "a")
        let tiled = bridge.frames
        bridge.mutateThenFailApplyCalls = [bridge.frameCalls + 2]
        XCTAssertThrowsError(try coordinator.restoreTiledFrames(on: "a"))
        XCTAssertEqual(bridge.frames, tiled)
        bridge.mutateThenFailApplyCalls = []
        try coordinator.restoreTiledFrames(on: "a")
        try coordinator.switchTo("one", on: "a")
        XCTAssertEqual(bridge.frames["a"], CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(bridge.frames["b"], CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testReflowMutateThenThrowRollsBackFullFramesAndGatesFailedRollback() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["a", "b"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "one", on: "a")
        }
        bridge.mutateThenFailApplyCalls = [2]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(bridge.frames["a"]!.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(bridge.frames["b"]!.size, CGSize(width: 20, height: 20))
        bridge.mutateThenFailApplyCalls = [bridge.frameCalls + 2]
        bridge.failApplyCalls = [bridge.frameCalls + 3]
        XCTAssertThrowsError(try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertThrowsError(try coordinator.restoreTiledFrames(on: "a"))
        bridge.failApplyCalls = []
        bridge.mutateThenFailApplyCalls = []
        try coordinator.shutdown()
        XCTAssertFalse(coordinator.recoveryRequired)
    }

    func testShutdownRestoresOriginalSizeAfterTiling() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 25)
        try coordinator.assign("w", to: "one", on: "a")
        try coordinator.reflow(on: "a", usableBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try coordinator.shutdown()
        XCTAssertEqual(bridge.frames["w"], CGRect(x: 10, y: 10, width: 20, height: 25))
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
        bridge.failApplyCalls = [bridge.frameCalls + 1]
        XCTAssertThrowsError(try coordinator.shutdown())
        XCTAssertTrue(coordinator.recoveryRequired)
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
        bridge.failApplyCalls = []
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
        XCTAssertEqual(bridge.calls, before)
        XCTAssertEqual(bridge.frameCalls, 1)
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

    func testResizedWindowUsesOriginalSizeForRestoreLayout() throws {
        let (coordinator, bridge) = try setup()
        for id: WindowID in ["first", "second"] {
            bridge.frames[id] = CGRect(x: 10, y: 10, width: 20, height: 20)
            try coordinator.assign(id, to: "two", on: "a")
        }
        bridge.frames["first"]!.size = CGSize(width: 70, height: 30)
        bridge.frames["second"]!.size = CGSize(width: 50, height: 30)
        try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)])
        XCTAssertEqual(bridge.frames["first"]!.origin, CGPoint(x: 200, y: 0))
        XCTAssertEqual(bridge.frames["second"]!.origin, CGPoint(x: 220, y: 0))
        XCTAssertEqual(bridge.frames["first"]!.size, CGSize(width: 20, height: 20))
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
        try coordinator.shutdown(connectedDisplays: ["b": CGRect(x: 200, y: 0, width: 100, height: 100)])
        XCTAssertEqual(bridge.frames["w"]!.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(bridge.calls, before)
        XCTAssertThrowsError(try coordinator.model.membership(of: "w"))
    }

    func testDisconnectedRestoreFailureRetainsOwnershipAndBlocksExit() throws {
        let (coordinator, bridge) = try setup()
        bridge.frames["w"] = CGRect(x: 10, y: 10, width: 20, height: 20)
        try coordinator.assign("w", to: "two", on: "a")
        bridge.failApplyCalls = [bridge.frameCalls + 1]
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
        bridge.failApplyCalls = [bridge.frameCalls + 1]
        XCTAssertThrowsError(try coordinator.removeDisplay("a"))
        XCTAssertEqual(try coordinator.model.membership(of: "w").display, "a")
    }
}
