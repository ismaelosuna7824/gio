import XCTest
@testable import GioCore

/// FI-10: an app that keeps restoring its own frame after Gio wrote it is
/// counted; at the cap the window yields to the app.
final class SnapBackBookTests: XCTestCase {
    private let id = WindowID(pid: 10, elementID: 1)
    private let other = WindowID(pid: 10, elementID: 2)

    /// One snap-back `after` seconds past a write at `written`.
    private func snap(
        _ book: inout SnapBackBook, at time: TimeInterval, writtenAt written: TimeInterval?,
        dragging: Bool = false, window: WindowID? = nil
    ) -> SnapBackVerdict {
        book.note(window ?? id, at: time, lastWrite: written, dragging: dragging)
    }

    func testAChangeShortlyAfterGiosWriteCountsAndTheThirdYields() {
        var book = SnapBackBook()
        XCTAssertEqual(snap(&book, at: 0.5, writtenAt: 0), .counted(1))
        XCTAssertEqual(snap(&book, at: 1.5, writtenAt: 0.8), .counted(2))
        XCTAssertEqual(snap(&book, at: 2.5, writtenAt: 1.8), .yield(3))
    }

    func testAChangeLongAfterTheLastWriteIsTheAppsOwnAndNeverCounts() {
        var book = SnapBackBook()
        for time in [10.0, 20, 30, 40] {
            XCTAssertEqual(snap(&book, at: time, writtenAt: time - SnapBackBook.window - 0.1), .ignored)
        }
        XCTAssertEqual(snap(&book, at: 50, writtenAt: nil), .ignored, "never written by Gio")
        XCTAssertEqual(snap(&book, at: 51, writtenAt: 51 - SnapBackBook.window), .counted(1), "the bound counts")
    }

    func testSnapBacksSpreadBeyondTheSpanNeverReachTheCap() {
        var book = SnapBackBook()
        for index in 0..<10 {
            let time = TimeInterval(index) * (SnapBackBook.span / 2 + 0.1)
            XCTAssertNotEqual(snap(&book, at: time, writtenAt: time - 0.5), .yield(3), "snap \(index)")
        }
    }

    func testAUserDragNeverCounts() {
        var book = SnapBackBook()
        for time in [0.5, 1.0, 1.5, 2.0, 2.5] {
            XCTAssertEqual(snap(&book, at: time, writtenAt: time - 0.4, dragging: true), .ignored)
        }
        XCTAssertEqual(snap(&book, at: 3, writtenAt: 2.6), .counted(1))
    }

    func testTheYieldAndForgettingStartTheCountOver() {
        var book = SnapBackBook()
        for time in [0.5, 1.0] {
            _ = snap(&book, at: time, writtenAt: time - 0.4)
        }
        XCTAssertEqual(snap(&book, at: 1.5, writtenAt: 1.1), .yield(3))
        XCTAssertEqual(snap(&book, at: 2.0, writtenAt: 1.6), .counted(1), "tiled again: a fresh count")
        XCTAssertEqual(snap(&book, at: 2.5, writtenAt: 2.1), .counted(2))
        book.forget(id)
        XCTAssertEqual(snap(&book, at: 3.0, writtenAt: 2.6), .counted(1), "purged or re-registered")
    }

    func testWindowsAreCountedApart() {
        var book = SnapBackBook()
        XCTAssertEqual(snap(&book, at: 0.5, writtenAt: 0), .counted(1))
        XCTAssertEqual(snap(&book, at: 0.6, writtenAt: 0, window: other), .counted(1))
        XCTAssertEqual(snap(&book, at: 0.7, writtenAt: 0), .counted(2))
    }
}
