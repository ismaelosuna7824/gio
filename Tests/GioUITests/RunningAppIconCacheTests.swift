import AppKit
import XCTest
@testable import GioUI

/// PA-13: window rows and tiles look an app's icon up once per process and
/// draw a small raster, not the full icon on every render.
@MainActor
final class RunningAppIconCacheTests: XCTestCase {
    private var lookups: [pid_t] = []

    private func cache(icons: [pid_t: NSImage]) -> RunningAppIconCache {
        RunningAppIconCache { [unowned self] pid in
            lookups.append(pid)
            return icons[pid]
        }
    }

    func testRendersOfTheSameProcessLookItUpOnce() throws {
        let cache = cache(icons: [42: NSImage(size: NSSize(width: 1024, height: 1024))])

        let first = try XCTUnwrap(cache.icon(windowID: "42:7"))
        _ = cache.icon(windowID: "42:7")
        _ = cache.icon(windowID: "42:9")

        XCTAssertEqual(lookups, [42], "one lookup for every window of the process")
        XCTAssertEqual(first.width, AppIconResolver.pixelSize, "rasterized once at the drawn size")
    }

    func testAMissIsCachedToo() {
        let cache = cache(icons: [:])

        XCTAssertNil(cache.icon(windowID: "77:1"))
        XCTAssertNil(cache.icon(windowID: "77:1"))

        XCTAssertEqual(lookups, [77])
    }

    func testForgettingAPidLooksItUpAgain() {
        let cache = cache(icons: [:])
        _ = cache.icon(windowID: "77:1")

        cache.forget(pid: 77)
        _ = cache.icon(windowID: "77:1")

        XCTAssertEqual(lookups, [77, 77], "a reused pid gets a fresh icon")
    }

    func testIDsWithoutAProcessNeverLookUp() {
        let cache = cache(icons: [:])

        XCTAssertNil(cache.icon(windowID: "0:1"))
        XCTAssertNil(cache.icon(windowID: "abc"))

        XCTAssertEqual(lookups, [])
    }
}
