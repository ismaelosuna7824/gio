import XCTest
@testable import GioCore

/// WC-08: windows parked (or otherwise off-screen) come back fully inside
/// their display's visible frame, size kept, without stacking exactly.
final class RestorePlannerTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private let main = RestoreDisplay(
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 960)
    )
    private let second = RestoreDisplay(
        frame: CGRect(x: 1800, y: 0, width: 1200, height: 800),
        visibleFrame: CGRect(x: 1800, y: 0, width: 1200, height: 800)
    )

    func testFullyVisibleWindowIsUntouched() {
        let plan = planRestore(
            windows: [id(1): CGRect(x: 100, y: 100, width: 700, height: 500)],
            displays: [main]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testLeftParkedWindowComesBackInsideKeepingSize() throws {
        let parked = CGRect(x: -699, y: 8, width: 700, height: 900)
        let plan = planRestore(windows: [id(1): parked], displays: [main])
        let restored = try XCTUnwrap(plan[id(1)])
        XCTAssertEqual(restored.size, parked.size)
        XCTAssertTrue(main.visibleFrame.contains(restored))
    }

    func testRightParkedWindowComesBackInside() throws {
        let parked = CGRect(x: 1799, y: 8, width: 700, height: 900)
        let plan = planRestore(windows: [id(1): parked], displays: [main])
        let restored = try XCTUnwrap(plan[id(1)])
        XCTAssertEqual(restored.size, parked.size)
        XCTAssertTrue(main.visibleFrame.contains(restored))
    }

    func testCornerParkedWindowComesBackInside() throws {
        let parked = CGRect(x: 1799, y: -899, width: 700, height: 900)
        let plan = planRestore(windows: [id(1): parked], displays: [main])
        let restored = try XCTUnwrap(plan[id(1)])
        XCTAssertTrue(main.visibleFrame.contains(restored))
    }

    func testOversizedWindowShrinksToFitTheVisibleFrame() throws {
        let parked = CGRect(x: 1799, y: 0, width: 2400, height: 1200)
        let plan = planRestore(windows: [id(1): parked], displays: [main])
        let restored = try XCTUnwrap(plan[id(1)])
        XCTAssertTrue(main.visibleFrame.contains(restored))
        XCTAssertEqual(restored.width, main.visibleFrame.width)
        XCTAssertEqual(restored.height, main.visibleFrame.height)
    }

    func testRestoredWindowsCascadeInsteadOfStacking() throws {
        var windows: [WindowID: CGRect] = [:]
        for element in 1...4 {
            windows[id(UInt64(element))] = CGRect(x: -699, y: 8, width: 700, height: 500)
        }
        let plan = planRestore(windows: windows, displays: [main])
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(Set(plan.values.map { "\($0.origin.x),\($0.origin.y)" }).count, 4)
        for frame in plan.values {
            XCTAssertTrue(main.visibleFrame.contains(frame))
        }
    }

    func testCascadeOrderIsDeterministicByWindowID() {
        var windows: [WindowID: CGRect] = [:]
        for element in 1...3 {
            windows[id(UInt64(element))] = CGRect(x: 1799, y: 8, width: 600, height: 400)
        }
        XCTAssertEqual(
            planRestore(windows: windows, displays: [main]),
            planRestore(windows: windows, displays: [main])
        )
    }

    func testWindowRestoresOntoTheDisplayItBelongsTo() throws {
        // Parked at the left edge of the second display.
        let parked = CGRect(x: 1800 - 599, y: 8, width: 600, height: 500)
        let onSecond = CGRect(x: 3000 - 1, y: 8, width: 600, height: 500)
        let plan = planRestore(
            windows: [id(1): onSecond, id(2): parked], displays: [main, second]
        )
        XCTAssertTrue(second.visibleFrame.contains(try XCTUnwrap(plan[id(1)])))
    }

    func testWindowOutsideEveryDisplayGoesToTheNearestOne() throws {
        let lost = CGRect(x: 9000, y: 8, width: 600, height: 500)
        let plan = planRestore(windows: [id(1): lost], displays: [main, second])
        XCTAssertTrue(second.visibleFrame.contains(try XCTUnwrap(plan[id(1)])))
    }

    func testNoDisplaysPlansNothing() {
        let plan = planRestore(
            windows: [id(1): CGRect(x: -699, y: 8, width: 700, height: 500)], displays: []
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testWindowOverlappingTheDockAreaButOnDisplayIsUntouched() {
        // Inside the full display frame, just below the visible frame.
        let plan = planRestore(
            windows: [id(1): CGRect(x: 100, y: -0, width: 700, height: 990)],
            displays: [main]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: Reconciler

    private final class MockActuator: WindowActuator {
        var frames: [WindowID: CGRect] = [:]
        var sets: [WindowID] = []
        func frame(of id: WindowID) throws -> CGRect? { frames[id] }
        func setFrame(_ frame: CGRect, for id: WindowID) throws {
            sets.append(id)
            frames[id] = frame
        }
        func focus(id: WindowID) throws {}
    }

    func testReconcilerRestoresOnlyOffscreenWindows() {
        let actuator = MockActuator()
        actuator.frames = [
            id(1): CGRect(x: 100, y: 100, width: 700, height: 500),
            id(2): CGRect(x: -699, y: 8, width: 700, height: 500),
        ]
        let report = WindowReconciler(actuator: actuator).restoreOffscreen(
            ids: [id(1), id(2)], displays: [main]
        )
        XCTAssertEqual(actuator.sets, [id(2)])
        XCTAssertEqual(report.applied, [id(2)])
        XCTAssertTrue(main.visibleFrame.contains(actuator.frames[id(2)]!))
    }

    func testReconcilerReportsVanishedWindows() {
        let actuator = MockActuator()
        let report = WindowReconciler(actuator: actuator).restoreOffscreen(
            ids: [id(9)], displays: [main]
        )
        XCTAssertEqual(report.vanished, [id(9)])
        XCTAssertTrue(actuator.sets.isEmpty)
    }
}
