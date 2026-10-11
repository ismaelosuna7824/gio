import XCTest
@testable import GioCore

/// TG-03: whether trackpad gestures run, and why not (log-safe reasons);
/// the log says it once at startup and again only when it changes.
final class GestureStatusTests: XCTestCase {
    func testReasons() {
        XCTAssertEqual(
            gestureSourceStatus(enabled: true, missingSymbols: nil, devices: 0),
            GestureSourceStatus(available: false, reason: "not-loaded")
        )
        XCTAssertEqual(
            gestureSourceStatus(enabled: true, missingSymbols: ["MTDeviceCreateList", "MTDeviceStart"], devices: 0),
            GestureSourceStatus(available: false, reason: "missing-symbols:MTDeviceCreateList,MTDeviceStart")
        )
        XCTAssertEqual(
            gestureSourceStatus(enabled: false, missingSymbols: [], devices: 1),
            GestureSourceStatus(available: false, reason: "config-off")
        )
        XCTAssertEqual(
            gestureSourceStatus(enabled: true, missingSymbols: [], devices: 0),
            GestureSourceStatus(available: false, reason: "no-trackpad")
        )
        XCTAssertEqual(
            gestureSourceStatus(enabled: true, missingSymbols: [], devices: 2),
            GestureSourceStatus(available: true, reason: "devices=2")
        )
    }

    func testMissingSymbolsWinOverTheConfig() {
        XCTAssertEqual(
            gestureSourceStatus(enabled: false, missingSymbols: ["MTDeviceStop"], devices: 0).reason,
            "missing-symbols:MTDeviceStop"
        )
    }

    func testLogGateSpeaksOnceThenOnChange() {
        var gate = GestureStatusLogGate()
        let missing = GestureSourceStatus(available: false, reason: "missing-symbols:MTDeviceStart")
        XCTAssertEqual(gate.line(for: missing), "gestures available=false reason=missing-symbols:MTDeviceStart")
        XCTAssertNil(gate.line(for: missing))
        XCTAssertEqual(
            gate.line(for: GestureSourceStatus(available: true, reason: "devices=1")),
            "gestures available=true reason=devices=1"
        )
    }
}
