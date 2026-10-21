import AppKit
import XCTest
@testable import GioUI

/// PA-22: every launch redrew all ~91 launcher icons from their bundles
/// (`launcher appsReady ms=555-1141 drawn=91 reason=startup`). The drawn
/// icons are kept on disk, keyed by bundle path and Info.plist date, so a
/// launch draws only what changed. Temp directories only.
@MainActor
final class LauncherIconStoreTests: XCTestCase {
    private nonisolated let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gio-launcher-icons-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var storeURL: URL {
        root.appendingPathComponent("cache/launcher-icons.plist")
    }

    private func icon() -> NSImage {
        scaledLauncherIcon(NSImage(size: NSSize(width: 512, height: 512)), side: LauncherAppCatalog.iconSide)
    }

    func testIconsRoundTripAtTheirPointSize() throws {
        let store = LauncherIconStore(url: storeURL)
        store.save(icons: ["/Applications/A.app": icon()], stamps: ["/Applications/A.app": 42], side: 30)

        let loaded = store.load(side: 30)
        XCTAssertEqual(loaded.stamps, ["/Applications/A.app": 42])
        let image = try XCTUnwrap(loaded.icons["/Applications/A.app"])
        XCTAssertEqual(image.size, NSSize(width: 30, height: 30))
        XCTAssertEqual(image.representations.first?.pixelsWide, 60)
    }

    func testAnotherSizeOrAnUnreadableFileStartsEmpty() throws {
        let store = LauncherIconStore(url: storeURL)
        XCTAssertTrue(store.load(side: 30).icons.isEmpty, "no file yet")
        store.save(icons: ["/A.app": icon()], stamps: ["/A.app": 1], side: 30)
        XCTAssertTrue(store.load(side: 24).icons.isEmpty, "drawn for another size")
        try Data("not a plist".utf8).write(to: storeURL)
        let garbage = store.load(side: 30)
        XCTAssertTrue(garbage.icons.isEmpty)
        XCTAssertTrue(garbage.stamps.isEmpty)
    }

    private func makeApp(_ name: String) throws {
        let contents = root.appendingPathComponent("apps/\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.test.\(name)"], format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private final class DrawCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var drawn: [String] = []
        var paths: [String] { lock.withLock { drawn } }
        func note(_ path: String) { lock.withLock { drawn.append((path as NSString).lastPathComponent) } }
    }

    private func scanOnce(_ catalog: LauncherAppCatalog) {
        let landed = expectation(description: "scan landed")
        catalog.onChange = { landed.fulfill() }
        catalog.start()
        wait(for: [landed], timeout: 5)
        catalog.stop()
    }

    func testTheNextLaunchDrawsOnlyWhatChanged() throws {
        try makeApp("Alpha")
        try makeApp("Beta")
        let directories = [root.appendingPathComponent("apps").path]
        let firstDraws = DrawCounter()
        let first = LauncherAppCatalog(
            directories: directories, iconStore: LauncherIconStore(url: storeURL),
            drawIcon: { path, side in
                firstDraws.note(path)
                return scaledLauncherIcon(NSImage(size: NSSize(width: 64, height: 64)), side: side)
            }
        )
        scanOnce(first)
        XCTAssertEqual(firstDraws.paths.sorted(), ["Alpha.app", "Beta.app"])

        // A new process: nothing in memory, the store on disk. Beta changed.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: root.appendingPathComponent("apps/Beta.app/Contents/Info.plist").path
        )
        let secondDraws = DrawCounter()
        let second = LauncherAppCatalog(
            directories: directories, iconStore: LauncherIconStore(url: storeURL),
            drawIcon: { path, side in
                secondDraws.note(path)
                return scaledLauncherIcon(NSImage(size: NSSize(width: 64, height: 64)), side: side)
            }
        )
        scanOnce(second)
        XCTAssertEqual(secondDraws.paths, ["Beta.app"])
        let alpha = root.appendingPathComponent("apps/Alpha.app").path
        XCTAssertNotNil(second.icon(for: .app(name: "Alpha", bundleID: "com.test.Alpha", path: alpha)))
    }
}
