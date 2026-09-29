import CoreGraphics
import XCTest
import GioCore
@testable import GioMacOS

/// FI-05: the WindowServer list is parsed into Cocoa-space `ServerWindow`s;
/// only layer-0 windows with a pid and bounds are kept, and no title key is
/// ever read.
final class WindowServerSnapshotTests: XCTestCase {
    private func entry(pid: Int, layer: Int, x: Double, y: Double, w: Double, h: Double) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
        ]
    }

    func testKeepsLayerZeroWindowsAndFlipsToCocoa() {
        let windows = parseWindowServerEntries(
            [entry(pid: 5, layer: 0, x: 10, y: 100, w: 600, h: 400)], displayHeight: 1000
        )
        XCTAssertEqual(windows, [ServerWindow(pid: 5, bounds: CGRect(x: 10, y: 500, width: 600, height: 400))])
    }

    func testDropsOverlaysAndMalformedEntries() {
        let windows = parseWindowServerEntries(
            [
                entry(pid: 5, layer: 25, x: 0, y: 0, w: 100, h: 20),
                [kCGWindowLayer as String: 0],
                [kCGWindowOwnerPID as String: 7, kCGWindowLayer as String: 0],
            ],
            displayHeight: 1000
        )
        XCTAssertEqual(windows, [])
    }
}
