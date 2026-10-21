import CoreGraphics
import Foundation
import XCTest
@testable import GioCore

/// PA-24: a minimum an app enforces (WhatsApp 970 pt, Figma and NoteX 900)
/// was learned from one clamped write per window, in memory, so every launch
/// laid those windows out too narrow once and they overlapped their
/// neighbour (log: `frameMismatch requested=888 actual=970` after each of
/// five launches). What a window learns is kept per app, on disk, and the
/// next launch lays the app's windows out at it from the first pass.
final class AppMinimumSizesTests: XCTestCase {
    private func window(_ element: UInt64, pid: pid_t = 7, app: String, bundle: String? = nil) -> ManagedWindow {
        ManagedWindow(
            id: WindowID(pid: pid, elementID: element), pid: pid, application: app, bundleID: bundle,
            title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: .tiled
        )
    }

    func testAnAppKeepsTheLargestMinimumAnyOfItsWindowsShowed() {
        var minimums = AppMinimumSizes()
        let whatsapp = window(1, app: "WhatsApp", bundle: "net.whatsapp.WhatsApp")
        XCTAssertTrue(minimums.record(CGSize(width: 970, height: 0), for: whatsapp))
        XCTAssertFalse(minimums.record(CGSize(width: 900, height: 0), for: whatsapp), "smaller: nothing new")
        XCTAssertTrue(minimums.record(CGSize(width: 970, height: 500), for: whatsapp))
        XCTAssertEqual(minimums.size(for: window(2, pid: 99, app: "WhatsApp", bundle: "net.whatsapp.WhatsApp")),
                       CGSize(width: 970, height: 500), "a new pid of the same app")
    }

    func testTheBundleIDIsTheKeyWhenKnownElseTheName() {
        var minimums = AppMinimumSizes()
        _ = minimums.record(CGSize(width: 900, height: 0), for: window(1, app: "Figma", bundle: "com.figma.Desktop"))
        XCTAssertNil(minimums.size(for: window(2, app: "Figma")), "same name, no bundle id: another key")
        _ = minimums.record(CGSize(width: 640, height: 0), for: window(3, app: "NoteX"))
        XCTAssertEqual(minimums.size(for: window(4, app: "NoteX"))?.width, 640)
    }

    func testThePassUsesWhatThisSessionLearnedElseTheAppMinimum() {
        var minimums = AppMinimumSizes()
        let figma = window(1, app: "Figma", bundle: "com.figma.Desktop")
        let other = window(2, app: "Figma", bundle: "com.figma.Desktop")
        let notes = window(3, app: "Notes", bundle: "com.apple.Notes")
        _ = minimums.record(CGSize(width: 900, height: 0), for: figma)
        let learned = [other.id: CGSize(width: 950, height: 0)]

        let effective = minimums.effective(learned: learned, windows: [figma, other, notes])
        XCTAssertEqual(effective[figma.id]?.width, 900, "from an earlier launch")
        XCTAssertEqual(effective[other.id]?.width, 950, "this session's evidence wins")
        XCTAssertNil(effective[notes.id], "an app that never clamped")
        XCTAssertEqual(AppMinimumSizes().effective(learned: learned, windows: [figma]), learned)
    }

    func testTheStoreRoundTripsAndAnUnreadableFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-min-sizes-\(UUID().uuidString)/app-minimum-sizes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppMinimumSizeStore(url: url)
        XCTAssertEqual(store.load(), AppMinimumSizes(), "no file yet")

        var minimums = AppMinimumSizes()
        _ = minimums.record(CGSize(width: 970, height: 0), for: window(1, app: "WhatsApp", bundle: "net.whatsapp.WhatsApp"))
        store.save(minimums)
        XCTAssertEqual(store.load(), minimums)

        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), AppMinimumSizes())
    }
}
