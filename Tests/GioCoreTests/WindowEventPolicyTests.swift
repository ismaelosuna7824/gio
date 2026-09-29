import XCTest
@testable import GioCore

final class WindowEventPolicyTests: XCTestCase {
    private let id = WindowID(pid: 10, elementID: 1)
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    // MARK: Notification mapping

    func testAXNotificationNamesMapToKinds() {
        XCTAssertEqual(WindowEventKind(axNotification: "AXWindowCreated"), .windowCreated)
        XCTAssertEqual(WindowEventKind(axNotification: "AXUIElementDestroyed"), .destroyed)
        XCTAssertEqual(WindowEventKind(axNotification: "AXWindowMoved"), .moved)
        XCTAssertEqual(WindowEventKind(axNotification: "AXWindowResized"), .resized)
        XCTAssertEqual(WindowEventKind(axNotification: "AXWindowMiniaturized"), .miniaturized)
        XCTAssertEqual(WindowEventKind(axNotification: "AXWindowDeminiaturized"), .deminiaturized)
        XCTAssertEqual(WindowEventKind(axNotification: "AXTitleChanged"), .titleChanged)
        XCTAssertEqual(WindowEventKind(axNotification: "AXFocusedWindowChanged"), .focusedWindowChanged)
    }

    func testUnknownNotificationMapsToNil() {
        XCTAssertNil(WindowEventKind(axNotification: "AXSomethingElse"))
    }

    // MARK: Action table

    func testCreatedUnknownWindowRegisters() {
        XCTAssertEqual(windowEventAction(for: .windowCreated, isKnownWindow: false), .register)
    }

    func testCreatedKnownWindowIsIgnored() {
        XCTAssertEqual(windowEventAction(for: .windowCreated, isKnownWindow: true), .ignore)
    }

    func testDestroyedKnownWindowIsRemoved() {
        XCTAssertEqual(windowEventAction(for: .destroyed, isKnownWindow: true), .remove)
    }

    func testDestroyedUnknownWindowIsIgnored() {
        XCTAssertEqual(windowEventAction(for: .destroyed, isKnownWindow: false), .ignore)
    }

    func testResizedInvalidatesTileabilityMovedDoesNot() {
        XCTAssertEqual(
            windowEventAction(for: .resized, isKnownWindow: true),
            .frameChanged(invalidateTileability: true)
        )
        XCTAssertEqual(
            windowEventAction(for: .moved, isKnownWindow: true),
            .frameChanged(invalidateTileability: false)
        )
    }

    func testFrameEventsForUnknownWindowsAreIgnored() {
        XCTAssertEqual(windowEventAction(for: .resized, isKnownWindow: false), .ignore)
        XCTAssertEqual(windowEventAction(for: .moved, isKnownWindow: false), .ignore)
    }

    func testMinimizeEventsRouteToLifecycleForKnownWindows() {
        XCTAssertEqual(windowEventAction(for: .miniaturized, isKnownWindow: true), .minimize)
        XCTAssertEqual(windowEventAction(for: .deminiaturized, isKnownWindow: true), .restore)
    }

    func testDeminiaturizedUnknownWindowRegisters() {
        XCTAssertEqual(windowEventAction(for: .deminiaturized, isKnownWindow: false), .register)
    }

    func testTitleChangeUpdatesKnownWindowOnly() {
        XCTAssertEqual(windowEventAction(for: .titleChanged, isKnownWindow: true), .updateTitle)
        XCTAssertEqual(windowEventAction(for: .titleChanged, isKnownWindow: false), .ignore)
    }

    func testFocusChangeRequestsResync() {
        XCTAssertEqual(windowEventAction(for: .focusedWindowChanged, isKnownWindow: false), .resync)
        XCTAssertEqual(windowEventAction(for: .focusedWindowChanged, isKnownWindow: true), .resync)
    }

    // MARK: Echo gate

    func testNoRecordedWriteIsNeverAnEcho() {
        let gate = WriteEchoGate()
        XCTAssertFalse(gate.isEcho(id, observed: frame, at: 0))
    }

    func testMatchingFrameWithinToleranceIsEcho() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 0)
        let near = frame.offsetBy(dx: 1, dy: -1)
        XCTAssertTrue(gate.isEcho(id, observed: near, at: 60))
    }

    func testDifferentFrameOutsideSuppressionWindowIsNotEcho() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 0)
        let dragged = frame.offsetBy(dx: 40, dy: 0)
        XCTAssertFalse(gate.isEcho(id, observed: dragged, at: WriteEchoGate.suppression + 1))
    }

    func testAnyFrameJustAfterOurWriteIsSuppressed() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 10)
        // Window clamped to a minimum size: does not match, but is ours.
        let clamped = CGRect(x: 100, y: 100, width: 900, height: 600)
        XCTAssertTrue(gate.isEcho(id, observed: clamped, at: 10 + WriteEchoGate.suppression / 2))
    }

    func testEchoIsPerWindow() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 0)
        let other = WindowID(pid: 10, elementID: 2)
        XCTAssertFalse(gate.isEcho(other, observed: frame, at: 0.01))
    }

    func testForgetDropsEntry() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 0)
        gate.forget(id)
        XCTAssertFalse(gate.isEcho(id, observed: frame, at: 0.01))
    }

    func testRecordAppliedReplacesPreviousFrame() {
        var gate = WriteEchoGate()
        gate.recordApplied([id: frame], at: 0)
        let next = frame.offsetBy(dx: 300, dy: 0)
        gate.recordApplied([id: next], at: 5)
        XCTAssertFalse(gate.isEcho(id, observed: frame, at: 100))
        XCTAssertTrue(gate.isEcho(id, observed: next, at: 100))
    }

    // MARK: Registration retry

    func testRegistrationRetryDelaysGrowThenStop() {
        let delays = (0..<WindowRegistrationRetry.maxRetries).compactMap {
            WindowRegistrationRetry.delay(afterFailedAttempt: $0)
        }
        XCTAssertEqual(delays.count, WindowRegistrationRetry.maxRetries)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertNil(WindowRegistrationRetry.delay(afterFailedAttempt: WindowRegistrationRetry.maxRetries))
    }
}
