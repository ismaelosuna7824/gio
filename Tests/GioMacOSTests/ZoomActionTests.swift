import CoreGraphics
import XCTest
import GioCore
@testable import GioMacOS

/// Native zoom: which Accessibility action of the window's green button is
/// the zoom. On current macOS the `AXZoomButton` attribute returns the
/// full-screen button (`AXPress` enters full screen) whose `AXZoomWindow`
/// action is the zoom itself (verified read-only on live windows).
final class ZoomActionTests: XCTestCase {
    func testPrefersTheZoomWindowActionEvenOnAFullScreenButton() {
        XCTAssertEqual(
            zoomActionName(subrole: "AXFullScreenButton", actions: ["AXPress", "AXZoomWindow", "AXShowMenu"]),
            "AXZoomWindow"
        )
        XCTAssertEqual(zoomActionName(subrole: "AXZoomButton", actions: ["AXPress", "AXZoomWindow"]), "AXZoomWindow")
    }

    func testAClassicZoomButtonIsPressed() {
        XCTAssertEqual(zoomActionName(subrole: "AXZoomButton", actions: ["AXPress"]), "AXPress")
    }

    func testAFullScreenButtonWithoutZoomWindowIsNeverPressed() {
        // AXPress on it would enter native full screen (its own Space).
        XCTAssertNil(zoomActionName(subrole: "AXFullScreenButton", actions: ["AXPress"]))
        XCTAssertNil(zoomActionName(subrole: "AXFullScreenButton", actions: []))
    }

    func testAButtonWithNoUsableActionIsUnavailable() {
        XCTAssertNil(zoomActionName(subrole: "AXZoomButton", actions: []))
        XCTAssertNil(zoomActionName(subrole: nil, actions: ["AXShowMenu"]))
    }

    func testAnUnknownSubroleWithPressIsPressed() {
        XCTAssertEqual(zoomActionName(subrole: nil, actions: ["AXPress"]), "AXPress")
    }

    func testWindowServerBoundsAreConvertedToCocoa() {
        let entry: [String: Any] = [
            kCGWindowBounds as String: ["X": 10.0, "Y": 100.0, "Width": 600.0, "Height": 400.0],
        ]
        XCTAssertEqual(
            parseWindowBounds(entry, displayHeight: 1000), CGRect(x: 10, y: 500, width: 600, height: 400)
        )
        XCTAssertNil(parseWindowBounds([:], displayHeight: 1000))
    }
}
