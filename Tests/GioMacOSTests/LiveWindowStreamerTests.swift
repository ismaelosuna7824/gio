import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import GioCore
@testable import GioMacOS

final class LiveWindowStreamerTests: XCTestCase {
    private let ownPid: pid_t = 99
    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func id(_ pid: pid_t, _ element: UInt64) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    func testAdmitSkipsOwnPidAndOrdersById() {
        var book = LiveStreamBook()

        let admitted = book.admit(
            [id(2, 1): frame, id(ownPid, 7): frame, id(1, 5): frame], ownPid: ownPid, now: 0
        )

        XCTAssertEqual(admitted, [id(1, 5), id(2, 1)])
        XCTAssertEqual(book.streaming, [id(1, 5), id(2, 1)])
    }

    func testAdmitCapsConcurrentStreamsAtTheLimit() {
        var book = LiveStreamBook()
        let windows = Dictionary(uniqueKeysWithValues: (1...6).map { (id(1, UInt64($0)), frame) })

        let admitted = book.admit(windows, ownPid: ownPid, now: 0)

        XCTAssertEqual(admitted, (1...UInt64(liveLayerMaxStreams)).map { id(1, $0) })
    }

    func testRetargetAdmitsOnlyNewWindowsWithinTheRemainingSlots() {
        var book = LiveStreamBook()
        _ = book.admit([id(1, 1): frame, id(1, 2): frame], ownPid: ownPid, now: 0, limit: 3)

        let admitted = book.admit(
            [id(1, 1): frame, id(1, 3): frame, id(1, 4): frame], ownPid: ownPid, now: 5, limit: 3
        )

        XCTAssertEqual(admitted, [id(1, 3)])
        XCTAssertEqual(book.streaming, [id(1, 1), id(1, 2), id(1, 3)])
    }

    func testFirstCompleteFrameReportsMillisecondsSinceItsStartOnce() {
        var book = LiveStreamBook()
        _ = book.admit([id(1, 1): frame], ownPid: ownPid, now: 1_000_000)
        let generation = book.generation

        let first = book.deliver(id(1, 1), generation: generation, now: 43_600_000)
        let second = book.deliver(id(1, 1), generation: generation, now: 60_000_000)

        XCTAssertEqual(first, .deliver(firstFrameMilliseconds: 43))
        XCTAssertEqual(second, .deliver(firstFrameMilliseconds: nil))
    }

    func testFramesOfAStoppedGenerationAreDropped() {
        var book = LiveStreamBook()
        _ = book.admit([id(1, 1): frame], ownPid: ownPid, now: 0)
        let stale = book.generation
        _ = book.stopAll()
        _ = book.admit([id(1, 1): frame], ownPid: ownPid, now: 0)

        XCTAssertEqual(book.deliver(id(1, 1), generation: stale, now: 1), .drop)
        XCTAssertEqual(book.deliver(id(1, 2), generation: book.generation, now: 1), .drop)
    }

    func testStopAllReportsStreamsAndDeliveredFramesThenResets() {
        var book = LiveStreamBook()
        _ = book.admit([id(1, 1): frame, id(1, 2): frame], ownPid: ownPid, now: 0)
        let generation = book.generation
        _ = book.deliver(id(1, 1), generation: generation, now: 1)
        _ = book.deliver(id(1, 1), generation: generation, now: 2)
        _ = book.deliver(id(1, 2), generation: generation, now: 3)

        let stopped = book.stopAll()
        let again = book.stopAll()

        XCTAssertEqual(stopped.count, 2)
        XCTAssertEqual(stopped.frames, 3)
        XCTAssertEqual(again.count, 0)
        XCTAssertEqual(again.frames, 0)
        XCTAssertTrue(book.streaming.isEmpty)
        XCTAssertFalse(book.owns(id(1, 1), generation: generation))
    }

    func testDroppedStreamFreesItsSlotOnlyForItsOwnGeneration() {
        var book = LiveStreamBook()
        _ = book.admit([id(1, 1): frame], ownPid: ownPid, now: 0, limit: 1)
        let generation = book.generation

        book.drop(id(1, 1), generation: generation + 1)
        XCTAssertTrue(book.owns(id(1, 1), generation: generation))

        book.drop(id(1, 1), generation: generation)
        XCTAssertFalse(book.owns(id(1, 1), generation: generation))
        XCTAssertEqual(book.admit([id(1, 2): frame], ownPid: ownPid, now: 0, limit: 1), [id(1, 2)])
    }

    func testOnlyCompleteFrameStatusIsDelivered() {
        XCTAssertTrue(liveFrameIsComplete(statusRawValue: SCFrameStatus.complete.rawValue))
        XCTAssertFalse(liveFrameIsComplete(statusRawValue: SCFrameStatus.idle.rawValue))
        XCTAssertFalse(liveFrameIsComplete(statusRawValue: SCFrameStatus.blank.rawValue))
        XCTAssertFalse(liveFrameIsComplete(statusRawValue: nil))
    }

    func testFramePointSizeDividesPixelsByTheScale() {
        XCTAssertEqual(liveFramePointSize(pixelWidth: 1600, pixelHeight: 1200, scale: 2), CGSize(width: 800, height: 600))
        XCTAssertEqual(liveFramePointSize(pixelWidth: 640, pixelHeight: 480, scale: 0), CGSize(width: 640, height: 480))
    }
}
