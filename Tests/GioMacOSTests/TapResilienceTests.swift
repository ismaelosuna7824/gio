import CoreGraphics
import XCTest
@testable import GioCore
@testable import GioMacOS

/// The tap must heal itself: macOS disables a tap whose callback is slow, and
/// a disabled tap is a dead keyboard for the whole session.
final class TapResilienceTests: XCTestCase {
    func testDisabledByTimeoutReenablesInsteadOfSwallowing() {
        XCTAssertEqual(tapEventAction(for: .tapDisabledByTimeout), .reenable(.timeout))
    }

    func testDisabledByUserInputReenables() {
        XCTAssertEqual(tapEventAction(for: .tapDisabledByUserInput), .reenable(.userInput))
    }

    func testOrdinaryEventsKeepTheirRoutes() {
        XCTAssertEqual(tapEventAction(for: .keyDown), .keyDown)
        XCTAssertEqual(tapEventAction(for: .mouseMoved), .mouseMoved)
        XCTAssertEqual(tapEventAction(for: .leftMouseDown), .mouseDown)
        XCTAssertEqual(tapEventAction(for: .rightMouseDown), .mouseDown)
        XCTAssertEqual(tapEventAction(for: .otherMouseDown), .mouseDown)
        XCTAssertEqual(tapEventAction(for: .scrollWheel), .passThrough)
    }

    func testMaskOmitsMouseMovedUnlessFocusFollowsMouse() {
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        let off = tapEventMask(observingMouseMoved: false)
        let on = tapEventMask(observingMouseMoved: true)
        XCTAssertEqual(off & moved, 0)
        XCTAssertEqual(on & moved, moved)
        // Keys and clicks are always observed.
        for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let bit = CGEventMask(1) << type.rawValue
            XCTAssertEqual(off & bit, bit)
            XCTAssertEqual(on & bit, bit)
        }
        XCTAssertEqual(on & ~moved, off)
    }

    func testTapRestartOnlyWhenMouseObservationChanges() {
        XCTAssertFalse(tapNeedsRestart(observingMouseMoved: false, wanted: false))
        XCTAssertFalse(tapNeedsRestart(observingMouseMoved: true, wanted: true))
        XCTAssertTrue(tapNeedsRestart(observingMouseMoved: false, wanted: true))
        XCTAssertTrue(tapNeedsRestart(observingMouseMoved: true, wanted: false))
    }

    func testWatchdogReenablesOnlyADisabledTap() {
        XCTAssertEqual(tapWatchdogAction(isEnabled: false), .reenable)
        XCTAssertEqual(tapWatchdogAction(isEnabled: true), .none)
    }

    func testReenableLogWarnsOnceThenDebug() {
        var tracker = TapReenableTracker()
        let first = tracker.record(.timeout)
        XCTAssertEqual(first.level, .warn)
        XCTAssertEqual(first.message, "hotkey tap re-enabled after timeout (count=1)")
        let second = tracker.record(.watchdog)
        XCTAssertEqual(second.level, .debug)
        XCTAssertEqual(second.message, "hotkey tap re-enabled after watchdog (count=2)")
        XCTAssertEqual(tracker.record(.userInput).level, .debug)
        XCTAssertEqual(tracker.count, 3)
    }
}
