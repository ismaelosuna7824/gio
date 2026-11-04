import XCTest
@testable import GioCore

/// WS-01: window-server notifications decoded from their raw payload, the
/// window number of each registered window, and what an event asks for.
final class WindowServerEventTests: XCTestCase {
    private let terminal = WindowID(pid: 37822, elementID: 5)

    /// Space created/destroyed window payload: space id (UInt64), then the
    /// window number (UInt32), as measured live (len=12).
    private func spacePayload(space: UInt64, number: UInt32) -> [UInt8] {
        withUnsafeBytes(of: space.littleEndian, Array.init) + withUnsafeBytes(of: number.littleEndian, Array.init)
    }

    func testDecodesCreatedAndDestroyedWindowNumbers() {
        XCTAssertEqual(
            decodeWindowServerEvent(type: 1325, payload: spacePayload(space: 1, number: 1338)), .created(1338)
        )
        XCTAssertEqual(
            decodeWindowServerEvent(type: 1326, payload: spacePayload(space: 1, number: 1338)), .destroyed(1338)
        )
    }

    func testShortPayloadsAndOtherTypesDecodeToNothing() {
        XCTAssertNil(decodeWindowServerEvent(type: 1325, payload: [1, 0, 0, 0]))
        XCTAssertNil(decodeWindowServerEvent(type: 808, payload: spacePayload(space: 1, number: 9)))
        XCTAssertNil(decodeWindowServerEvent(type: 806, payload: [1, 0]))
    }

    /// WS-03: moved and resized carry the window number alone (len=4, live).
    func testDecodesMovedAndResizedWindowNumbers() {
        XCTAssertEqual(decodeWindowServerEvent(type: 806, payload: [0x37, 0, 0, 0]), .moved(55))
        XCTAssertEqual(decodeWindowServerEvent(type: 807, payload: [0xFE, 0x03, 0, 0]), .resized(1022))
    }

    func testFrameChangeOfAKnownWindowIsHandledUnknownIgnored() {
        var book = WindowNumberBook()
        book.record(terminal, number: 7)
        XCTAssertEqual(windowServerEventAction(.moved(7), book: book), .frameChanged(terminal, resized: false))
        XCTAssertEqual(windowServerEventAction(.resized(7), book: book), .frameChanged(terminal, resized: true))
        XCTAssertEqual(windowServerEventAction(.moved(8), book: book), .ignore)
    }

    func testBookListsItsNumbersInOrder() {
        var book = WindowNumberBook()
        book.record(terminal, number: 9)
        book.record(WindowID(pid: 1, elementID: 1), number: 3)
        XCTAssertEqual(book.numbers, [3, 9])
    }

    /// WS-03: the AX path already saw this window's change (at or after the
    /// notice, give or take the delivery skew): the notice adds nothing.
    func testFrameNoticeDefersToTheAccessibilityEvent() {
        XCTAssertTrue(windowServerFrameChangeNeedsHandling(noticeAt: 10, lastAccessibilityEvent: nil))
        XCTAssertTrue(windowServerFrameChangeNeedsHandling(noticeAt: 10, lastAccessibilityEvent: 9))
        XCTAssertFalse(windowServerFrameChangeNeedsHandling(noticeAt: 10, lastAccessibilityEvent: 9.98))
        XCTAssertFalse(windowServerFrameChangeNeedsHandling(noticeAt: 10, lastAccessibilityEvent: 10.1))
    }

    func testBookMapsBothWaysAndForgets() {
        var book = WindowNumberBook()
        book.record(terminal, number: 1338)
        XCTAssertEqual(book.window(for: 1338), terminal)
        book.forget(terminal)
        XCTAssertNil(book.window(for: 1338))
    }

    /// A window that gets a new number (re-registered) drops the old one.
    func testBookKeepsOneNumberPerWindow() {
        var book = WindowNumberBook()
        book.record(terminal, number: 10)
        book.record(terminal, number: 11)
        XCTAssertNil(book.window(for: 10))
        XCTAssertEqual(book.window(for: 11), terminal)
    }

    func testCreatedUnknownNumberIsCheckedAfterTheGrace() {
        let book = WindowNumberBook()
        XCTAssertEqual(windowServerEventAction(.created(7), book: book), .checkArrival(7))
    }

    func testCreatedKnownNumberNeedsNothing() {
        var book = WindowNumberBook()
        book.record(terminal, number: 7)
        XCTAssertEqual(windowServerEventAction(.created(7), book: book), .ignore)
    }

    /// Rule 10: the event is not a purge; it asks for the proof scan.
    func testDestroyedKnownWindowAsksForItsProofScan() {
        var book = WindowNumberBook()
        book.record(terminal, number: 7)
        XCTAssertEqual(windowServerEventAction(.destroyed(7), book: book), .proveVanished(terminal))
        XCTAssertEqual(windowServerEventAction(.destroyed(8), book: book), .ignore)
    }

    func testArrivalScansOnlyAnUnregisteredNormalWindowOfAnotherApp() {
        var book = WindowNumberBook()
        let normal = WindowServerWindowOwner(pid: 42, layer: 0)
        XCTAssertEqual(windowServerArrivalScanPID(number: 7, book: book, owner: normal, ownPID: 1), 42)
        XCTAssertNil(windowServerArrivalScanPID(number: 7, book: book, owner: nil, ownPID: 1), "gone")
        XCTAssertNil(
            windowServerArrivalScanPID(number: 7, book: book, owner: WindowServerWindowOwner(pid: 42, layer: 101), ownPID: 1),
            "menus and popups"
        )
        XCTAssertNil(windowServerArrivalScanPID(number: 7, book: book, owner: normal, ownPID: 42), "Gio's own")
        book.record(WindowID(pid: 42, elementID: 1), number: 7)
        XCTAssertNil(windowServerArrivalScanPID(number: 7, book: book, owner: normal, ownPID: 1), "registered meanwhile")
    }
}
