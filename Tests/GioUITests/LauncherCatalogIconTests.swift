import AppKit
import XCTest
@testable import GioUI

/// PA-13: a window row's icon is looked up once per app, a miss included,
/// until the next scan lands.
@MainActor
final class LauncherCatalogIconTests: XCTestCase {
    private var lookups: [String] = []

    private func window(_ application: String) -> LauncherEntry {
        .window(id: "42:1", application: application, windowTitle: "", workspace: 1)
    }

    func testAWindowWithoutAKnownAppIsLookedUpOnceUntilTheNextScan() {
        let catalog = LauncherAppCatalog(directories: [], findRunningApp: { [unowned self] name in
            lookups.append(name)
            return nil
        })

        XCTAssertNil(catalog.icon(for: window("Ghost")))
        XCTAssertNil(catalog.icon(for: window("Ghost")))
        XCTAssertEqual(lookups, ["Ghost"], "the miss is cached")

        let landed = expectation(description: "scan landed")
        catalog.onChange = { landed.fulfill() }
        catalog.start()
        defer { catalog.stop() }
        wait(for: [landed], timeout: 5)

        XCTAssertNil(catalog.icon(for: window("Ghost")))
        XCTAssertEqual(lookups, ["Ghost", "Ghost"], "a landed scan clears it")
    }

    func testAKnownAppIsDrawnOnce() {
        let catalog = LauncherAppCatalog(directories: [], findRunningApp: { [unowned self] name in
            lookups.append(name)
            return (bundlePath: nil, icon: NSImage(size: NSSize(width: 512, height: 512)))
        })

        let icon = catalog.icon(for: window("Notes"))
        XCTAssertNotNil(icon)
        XCTAssertTrue(catalog.icon(for: window("Notes")) === icon)
        XCTAssertEqual(lookups, ["Notes"])
    }
}
