import CoreGraphics
import Foundation
import XCTest
@testable import GioCore

/// PA-24: a minimum an app enforces (WhatsApp 970 pt, Figma and NoteX 900)
/// was learned from one clamped write per window, in memory, so every launch
/// laid those windows out too narrow once and they overlapped their
/// neighbour. What a window learns is kept per app, on disk.
/// BUG-2 (live 2026-10-21): one clamp read too early taught Figma a 1784 pt
/// minimum (its old maximized width) and PA-24 kept it for every launch. An
/// app's minimum is now only used once two sessions learned the same value.
final class AppMinimumSizesTests: XCTestCase {
    private func window(_ element: UInt64, pid: pid_t = 7, app: String, bundle: String? = nil) -> ManagedWindow {
        ManagedWindow(
            id: WindowID(pid: pid, elementID: element), pid: pid, application: app, bundleID: bundle,
            title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: .tiled
        )
    }

    private let whatsapp = "net.whatsapp.WhatsApp"

    func testAMinimumIsUsedOnlyOnceTwoSessionsLearnedTheSameValue() {
        var minimums = AppMinimumSizes()
        let first = window(1, app: "WhatsApp", bundle: whatsapp)
        XCTAssertTrue(minimums.record(CGSize(width: 970, height: 0), for: first))
        XCTAssertNil(minimums.size(for: first), "seen once: not trusted yet")
        XCTAssertTrue(minimums.record(CGSize(width: 970.5, height: 0), for: first))
        XCTAssertEqual(minimums.size(for: window(2, pid: 99, app: "WhatsApp", bundle: whatsapp))?.width, 970,
                       "confirmed, for a new pid of the same app too")
    }

    func testAValueSeenOnceThatDiffersReplacesTheCandidate() {
        var minimums = AppMinimumSizes()
        let figma = window(1, app: "Figma", bundle: "com.figma.Desktop")
        minimums.record(CGSize(width: 1784, height: 600), for: figma)
        minimums.record(CGSize(width: 900, height: 600), for: figma)
        XCTAssertNil(minimums.size(for: figma), "the early 1784 was never confirmed")
        minimums.record(CGSize(width: 900, height: 600), for: figma)
        XCTAssertEqual(minimums.size(for: figma), CGSize(width: 900, height: 600))
    }

    func testTheBundleIDIsTheKeyWhenKnownElseTheName() {
        var minimums = AppMinimumSizes()
        let figma = window(1, app: "Figma", bundle: "com.figma.Desktop")
        minimums.record(CGSize(width: 900, height: 0), for: figma)
        minimums.record(CGSize(width: 900, height: 0), for: figma)
        XCTAssertNil(minimums.size(for: window(2, app: "Figma")), "same name, no bundle id: another key")
        let notes = window(3, app: "NoteX")
        minimums.record(CGSize(width: 640, height: 0), for: notes)
        minimums.record(CGSize(width: 640, height: 0), for: notes)
        XCTAssertEqual(minimums.size(for: window(4, app: "NoteX"))?.width, 640)
    }

    func testThePassUsesWhatThisSessionLearnedElseTheConfirmedAppMinimum() {
        var minimums = AppMinimumSizes()
        let figma = window(1, app: "Figma", bundle: "com.figma.Desktop")
        let other = window(2, app: "Figma", bundle: "com.figma.Desktop")
        let notes = window(3, app: "Notes", bundle: "com.apple.Notes")
        minimums.record(CGSize(width: 900, height: 0), for: figma)
        minimums.record(CGSize(width: 900, height: 0), for: figma)
        minimums.record(CGSize(width: 500, height: 0), for: notes)
        let learned = [other.id: CGSize(width: 950, height: 0)]

        let effective = minimums.effective(learned: learned, windows: [figma, other, notes])
        XCTAssertEqual(effective[figma.id]?.width, 900, "from earlier launches")
        XCTAssertEqual(effective[other.id]?.width, 950, "this session's evidence wins")
        XCTAssertNil(effective[notes.id], "seen once only")
        XCTAssertEqual(AppMinimumSizes().effective(learned: learned, windows: [figma]), learned)
    }

    func testTheStoreRoundTripsAndAnOldOrUnreadableFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-min-sizes-\(UUID().uuidString)/app-minimum-sizes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppMinimumSizeStore(url: url)
        XCTAssertEqual(store.load(), AppMinimumSizes(), "no file yet")

        var minimums = AppMinimumSizes()
        let app = window(1, app: "WhatsApp", bundle: whatsapp)
        minimums.record(CGSize(width: 970, height: 0), for: app)
        store.save(minimums)
        XCTAssertEqual(store.load(), minimums, "a candidate keeps its count")
        minimums.record(CGSize(width: 970, height: 0), for: app)
        store.save(minimums)
        XCTAssertEqual(store.load().size(for: app)?.width, 970)

        // PA-24's first format trusted single clamps (Figma 1784): dropped.
        try Data(#"{"bundle:com.figma.Desktop":[1784,600]}"#.utf8).write(to: url)
        XCTAssertEqual(store.load(), AppMinimumSizes())
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), AppMinimumSizes())
    }
}
