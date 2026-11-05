import CoreGraphics
import XCTest
@testable import GioMacOS

/// TG-12: Gio is in the scroll-event path only while tap-to-swipe is armed.
/// The hotkey tap never subscribes to scroll events; a separate scroll-only
/// tap exists while the setting is on, kept disabled (out of the event path)
/// and enabled only while armed.
final class ScrollSuppressionTapTests: XCTestCase {
    private let scrollBit = CGEventMask(1) << CGEventType.scrollWheel.rawValue

    func testTheHotkeyTapNeverSeesScrollEvents() {
        XCTAssertEqual(tapEventMask(observingMouseMoved: false) & scrollBit, 0)
        XCTAssertEqual(tapEventMask(observingMouseMoved: true) & scrollBit, 0)
    }

    func testTheScrollTapSubscribesToScrollEventsOnly() {
        XCTAssertEqual(scrollTapEventMask(), scrollBit)
    }

    func testScrollEventsAreSwallowedOnlyWhileArmed() {
        XCTAssertEqual(scrollTapEventAction(for: .scrollWheel, swallowing: true), .swallow)
        XCTAssertEqual(
            scrollTapEventAction(for: .scrollWheel, swallowing: false), .passAndDisable,
            "an enable that outlived the deadline takes the tap out of the path at its first event"
        )
        XCTAssertEqual(scrollTapEventAction(for: .keyDown, swallowing: true), .pass)
    }

    func testMacOSDisablingTheTapReenablesItOnlyWhileArmed() {
        XCTAssertEqual(scrollTapEventAction(for: .tapDisabledByTimeout, swallowing: true), .reenable)
        XCTAssertEqual(scrollTapEventAction(for: .tapDisabledByUserInput, swallowing: true), .reenable)
        XCTAssertEqual(scrollTapEventAction(for: .tapDisabledByTimeout, swallowing: false), .stayDisabled)
        XCTAssertEqual(scrollTapEventAction(for: .tapDisabledByUserInput, swallowing: false), .stayDisabled)
    }

    func testTheScrollTapExistsOnlyWhileTapToSwipeIsOn() {
        XCTAssertEqual(scrollTapLifecycle(running: false, wanted: true), .start)
        XCTAssertEqual(scrollTapLifecycle(running: true, wanted: false), .stop)
        XCTAssertEqual(scrollTapLifecycle(running: true, wanted: true), .none)
        XCTAssertEqual(scrollTapLifecycle(running: false, wanted: false), .none)
    }
}
