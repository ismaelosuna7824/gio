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

    func testMainScreenHeightFallsBackWithoutAScreen() {
        let probe = StubSystemProbe()
        probe.mainScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(probe.mainScreenHeight, 900)
        probe.mainScreenFrame = nil
        XCTAssertEqual(probe.mainScreenHeight, 1169)
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
