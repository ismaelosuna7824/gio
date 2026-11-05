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
        XCTAssertEqual(tapEventAction(for: .scrollWheel), .scrollWheel)
        XCTAssertEqual(tapEventAction(for: .flagsChanged), .passThrough)
    }

    func testMaskOmitsMouseMovedUnlessFocusFollowsMouse() {
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        let off = tapEventMask(TapSubscriptions())
        let on = tapEventMask(TapSubscriptions(mouseMoved: true))
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

    /// TG-10: scroll events cost a tap callback each, so the tap only
    /// subscribes to them while tap-to-swipe is on (to swallow them while armed).
    func testMaskOmitsScrollWheelUnlessTapToSwipe() {
        let scroll = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let off = tapEventMask(TapSubscriptions())
        let on = tapEventMask(TapSubscriptions(scrollWheel: true))
        XCTAssertEqual(off & scroll, 0)
        XCTAssertEqual(on & scroll, scroll)
        XCTAssertEqual(on & ~scroll, off)
        XCTAssertEqual(
            tapEventMask(TapSubscriptions(mouseMoved: true, scrollWheel: true)),
            tapEventMask(TapSubscriptions(mouseMoved: true)) | scroll
        )
    }

    func testTapRestartOnlyWhenASubscriptionChanges() {
        let none = TapSubscriptions()
        let moves = TapSubscriptions(mouseMoved: true)
        let scrolls = TapSubscriptions(scrollWheel: true)
        XCTAssertFalse(tapNeedsRestart(current: none, wanted: none))
        XCTAssertFalse(tapNeedsRestart(current: moves, wanted: moves))
        XCTAssertTrue(tapNeedsRestart(current: none, wanted: moves))
        XCTAssertTrue(tapNeedsRestart(current: moves, wanted: none))
        XCTAssertTrue(tapNeedsRestart(current: moves, wanted: TapSubscriptions(mouseMoved: true, scrollWheel: true)))
        XCTAssertTrue(tapNeedsRestart(current: scrolls, wanted: none))
    }

    /// TG-10: only an armed tap-to-swipe swallows scrolling; the tap asks
    /// the handler, which answers from a lock-guarded deadline.
    func testScrollWheelIsSwallowedOnlyWhenTheHandlerSaysSo() {
        XCTAssertFalse(tapSwallowsScroll(handler: nil))
        XCTAssertFalse(tapSwallowsScroll(handler: { false }))
        XCTAssertTrue(tapSwallowsScroll(handler: { true }))
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
