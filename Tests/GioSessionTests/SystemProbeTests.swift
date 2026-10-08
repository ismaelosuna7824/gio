import CoreGraphics
import Foundation
import XCTest
@testable import GioSession

final class SystemProbeTests: XCTestCase {
    func testMouseDownReadsPressedButtons() {
        let probe = StubSystemProbe()
        XCTAssertFalse(probe.isMouseDown)
        probe.pressedMouseButtons = 1
        XCTAssertTrue(probe.isMouseDown)
    }

    func testPrimaryScreenHeightFallsBackWithoutAScreen() {
        let probe = StubSystemProbe()
        probe.primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(probe.primaryScreenHeight, 900)
        probe.primaryScreenFrame = nil
        XCTAssertEqual(probe.primaryScreenHeight, 1169)
    }

    func testLivePrimaryScreenSitsAtTheCocoaOrigin() {
        // MM-01: the flip reference is the primary display, never the
        // key-window screen (`NSScreen.main`).
        if let frame = LiveSystemProbe().primaryScreenFrame {
            XCTAssertEqual(frame.origin, .zero)
        }
    }

    func testApplicationLabelFallsBackToPid() {
        let probe = StubSystemProbe()
        probe.names[42] = "Safari"
        XCTAssertEqual(probe.applicationLabel(42), "Safari")
        XCTAssertEqual(probe.applicationLabel(43), "pid43")
    }

    func testLiveProbeDoesNotReportAnUnusedPid() {
        let probe = LiveSystemProbe()
        XCTAssertFalse(probe.isRunning(-1))
        XCTAssertFalse(probe.isRegularApplication(-1))
        XCTAssertNil(probe.applicationName(-1))
        XCTAssertEqual(probe.applicationLabel(-1), "pid-1")
    }
}
