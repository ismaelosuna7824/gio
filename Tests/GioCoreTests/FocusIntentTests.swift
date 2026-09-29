import XCTest
@testable import GioCore

/// HD-01: only keyboard/IPC actions carry a focus intent, the intent waits
/// for the final exact pass of an animation, and Gio's own focus is never
/// mistaken for a user change of mind.
final class FocusIntentTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    func testHotkeyActionsCarryingFocusIntent() {
        let carrying: [HotkeyAction] = [
            .focusLeft, .focusRight, .focusUp, .focusDown,
            .moveLeft, .moveRight, .moveUp, .moveDown,
            .moveColumnLeft, .moveColumnRight,
            .workspace(3), .moveToWorkspace(2), .fullscreen,
            .consumeOrExpelLeft, .consumeOrExpelRight,
            .focusWorkspaceDown, .focusWorkspaceUp,
            .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
        ]
        let passive: [HotkeyAction] = [
            .toggleFloating, .switchPresetColumnWidth, .shrinkColumnWidth,
            .growColumnWidth, .maximizeColumn, .centerColumn,
        ]
        for action in carrying {
            XCTAssertTrue(action.carriesFocusIntent, "\(action)")
        }
        for action in passive {
            XCTAssertFalse(action.carriesFocusIntent, "\(action)")
        }
    }

    func testCLICommandsCarryingFocusIntent() {
        XCTAssertTrue(CLICommand.focus(.left).carriesFocusIntent)
        XCTAssertTrue(CLICommand.move(.down).carriesFocusIntent)
        XCTAssertTrue(CLICommand.workspace(2).carriesFocusIntent)
        for command: CLICommand in [.reload, .restart, .listWindows, .listWorkspaces, .layoutInfo, .status, .help] {
            XCTAssertFalse(command.carriesFocusIntent, "\(command)")
        }
    }

    func testPassivePassHandsNothingToTheReconciler() {
        var intent = FocusIntent()
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 0))
    }

    func testRequestedTargetIsHandedOnceOnAStaticPass() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertEqual(intent.take(motionStarting: false, parked: [], now: 0.1), id(2))
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 0.2))
    }

    func testTargetWaitsForTheFinalPassOfAnAnimation() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertNil(intent.take(motionStarting: true, parked: [], now: 0.01))
        XCTAssertNil(intent.take(motionStarting: true, parked: [], now: 0.05))
        XCTAssertEqual(intent.take(motionStarting: false, parked: [], now: 0.3), id(2))
    }

    func testParkedTargetIsNeverFocused() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertNil(intent.take(motionStarting: false, parked: [id(2)], now: 0.1))
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 0.2))
    }

    func testLatestRequestWinsAndNilRequestClears() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        intent.request(id(3), now: 0.05)
        XCTAssertEqual(intent.take(motionStarting: false, parked: [], now: 0.1), id(3))
        intent.request(id(4), now: 1)
        intent.request(nil, now: 1.1)
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 1.2))
    }

    func testCancelDropsPendingTargetAndGuard() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        intent.cancel()
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 0.1))
        XCTAssertFalse(intent.shouldIgnoreAdoption(of: id(3), now: 0.1))
    }

    func testAdoptionOfTheIntendedWindowIsNotIgnored() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertFalse(intent.shouldIgnoreAdoption(of: id(2), now: 0.1))
    }

    func testStaleEchoOfAnEarlierFocusIsIgnoredWhileIntentIsFresh() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertTrue(intent.shouldIgnoreAdoption(of: id(1), now: 0.1))
        _ = intent.take(motionStarting: false, parked: [], now: 0.3)
        XCTAssertTrue(intent.shouldIgnoreAdoption(of: id(1), now: 0.5))
    }

    func testAdoptionIsFreeAgainAfterTheGuardWindow() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        _ = intent.take(motionStarting: false, parked: [], now: 0.3)
        XCTAssertFalse(intent.shouldIgnoreAdoption(of: id(1), now: 0.3 + FocusIntent.settleWindow + 0.01))
    }

    func testReconcilerFocusesOnlyTheIntendedWindowAfterFrames() {
        final class Mock: WindowActuator {
            var frames: [WindowID: CGRect] = [:]
            var log: [String] = []
            func frame(of id: WindowID) throws -> CGRect? { frames[id] }
            func setFrame(_ frame: CGRect, for id: WindowID) throws {
                log.append("set \(id.elementID)")
                frames[id] = frame
            }
            func focus(id: WindowID) throws { log.append("focus \(id.elementID)") }
        }
        let actuator = Mock()
        actuator.frames = [id(1): .zero, id(2): .zero]
        let reconciler = WindowReconciler(actuator: actuator, concurrency: .serial)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        var intent = FocusIntent()

        // Passive pass: nothing is focused.
        reconciler.reconcile(
            frames: [id(1): target], focused: intent.take(motionStarting: false, parked: [], now: 0),
            currentlyFocused: nil
        )
        XCTAssertEqual(actuator.log, ["set 1"])

        // Intent pass: focus comes after the frame write.
        intent.request(id(2), now: 1)
        reconciler.reconcile(
            frames: [id(2): target], focused: intent.take(motionStarting: false, parked: [], now: 1),
            currentlyFocused: nil
        )
        XCTAssertEqual(actuator.log, ["set 1", "set 2", "focus 2"])
    }

    // MARK: - FI-06 focus now

    func testImmediateTakeHandsTheTargetAtMotionStartOnce() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        XCTAssertEqual(intent.takeImmediate(parked: [], now: 0.01), id(2))
        XCTAssertNil(intent.takeImmediate(parked: [], now: 0.02))
        XCTAssertNil(intent.take(motionStarting: false, parked: [], now: 0.3))
    }

    func testImmediateTakeNeverFocusesAParkedOrAbsentTarget() {
        var intent = FocusIntent()
        XCTAssertNil(intent.takeImmediate(parked: [], now: 0))
        intent.request(id(2), now: 0)
        XCTAssertNil(intent.takeImmediate(parked: [id(2)], now: 0.01))
        XCTAssertNil(intent.takeReassert(logicalFocus: id(2), frontmostPID: 99))
    }

    func testImmediateTakeKeepsTheEchoGuardForTheIntendedWindow() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        _ = intent.takeImmediate(parked: [], now: 0.01)
        XCTAssertTrue(intent.shouldIgnoreAdoption(of: id(1), now: 0.2))
        XCTAssertFalse(intent.shouldIgnoreAdoption(of: id(2), now: 0.2))
    }

    func testFinalPassReassertsOnlyWhenFocusDrifted() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        _ = intent.takeImmediate(parked: [], now: 0.01)
        // Still the logical focus and another app is frontmost: drifted.
        XCTAssertEqual(intent.takeReassert(logicalFocus: id(2), frontmostPID: 77), id(2))
        XCTAssertNil(intent.takeReassert(logicalFocus: id(2), frontmostPID: 77))
    }

    func testFinalPassDoesNotReassertWhenFocusHeldOrUserMovedOn() {
        var held = FocusIntent()
        held.request(id(2), now: 0)
        _ = held.takeImmediate(parked: [], now: 0.01)
        XCTAssertNil(held.takeReassert(logicalFocus: id(2), frontmostPID: 10))

        var moved = FocusIntent()
        moved.request(id(2), now: 0)
        _ = moved.takeImmediate(parked: [], now: 0.01)
        XCTAssertNil(moved.takeReassert(logicalFocus: id(3), frontmostPID: 77))

        var clicked = FocusIntent()
        clicked.request(id(2), now: 0)
        _ = clicked.takeImmediate(parked: [], now: 0.01)
        clicked.cancel()
        XCTAssertNil(clicked.takeReassert(logicalFocus: id(2), frontmostPID: 77))
    }

    func testNewRequestReplacesTheDeliveredTarget() {
        var intent = FocusIntent()
        intent.request(id(2), now: 0)
        _ = intent.takeImmediate(parked: [], now: 0.01)
        intent.request(id(3), now: 0.02)
        XCTAssertNil(intent.takeReassert(logicalFocus: id(2), frontmostPID: 77))
        XCTAssertEqual(intent.takeImmediate(parked: [], now: 0.03), id(3))
    }
}
