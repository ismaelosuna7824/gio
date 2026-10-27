import ApplicationServices
import XCTest
import GioCore
@testable import GioMacOS

/// PA-18d: a window subscribed by its created event or the app's attach is
/// not subscribed again when it is registered (`watch`). Elements are opaque
/// handles here; nothing is read, so no Accessibility permission is needed.
final class WindowSubscriptionTests: XCTestCase {
    private func refcon() -> EventRefcon {
        EventRefcon(pid: 4242, label: "app=Test pid=4242", emit: { _ in })
    }

    func testASubscribedWindowIsKnownByAnEqualHandle() {
        let box = refcon()
        XCTAssertFalse(box.isSubscribed(AXUIElementCreateApplication(60_001)))
        box.noteSubscribed(AXUIElementCreateApplication(60_001))
        XCTAssertTrue(box.isSubscribed(AXUIElementCreateApplication(60_001)))
        XCTAssertFalse(box.isSubscribed(AXUIElementCreateApplication(60_002)))
    }

    func testNotingTwiceKeepsOneEntry() {
        let box = refcon()
        let window = AXUIElementCreateApplication(60_001)
        box.noteSubscribed(window)
        box.noteSubscribed(window)
        XCTAssertEqual(box.subscribedCount, 1)
    }

    func testADestroyedWindowIsForgotten() {
        let box = refcon()
        let window = AXUIElementCreateApplication(60_001)
        let other = AXUIElementCreateApplication(60_002)
        box.noteSubscribed(window)
        box.noteSubscribed(other)
        box.forgetSubscription(window)
        XCTAssertFalse(box.isSubscribed(window))
        XCTAssertTrue(box.isSubscribed(other))
        XCTAssertEqual(box.subscribedCount, 1)
        box.forgetSubscription(window)
        XCTAssertEqual(box.subscribedCount, 1, "forgetting an unknown window is a no-op")
    }
}
