import Foundation
import GioCore
import XCTest
@testable import GioSession

/// TG-03: contact frames posted from MultitouchSupport's callback thread
/// reach the session queue in order, one drain per burst, and only the ones
/// a gesture can use cross over.
final class TouchFrameMailboxTests: XCTestCase {
    private final class Received: @unchecked Sendable {
        let lock = NSLock()
        var batches: [[TouchFrame]] = []

        func append(_ frames: [TouchFrame]) {
            lock.lock()
            batches.append(frames)
            lock.unlock()
        }
    }

    private func frame(_ t: TimeInterval, fingers: Int) -> TouchFrame {
        TouchFrame(timestamp: t, contacts: (0..<fingers).map { TouchContact(id: Int32($0), x: 0.5, y: 0.5) })
    }

    func testFramesWaitForTheSessionQueueAndArriveInOneOrderedBatch() {
        let scheduler = ManualScheduler()
        let received = Received()
        let mailbox = TouchFrameMailbox(scheduler: scheduler) { received.append($0) }
        mailbox.setMinimumFingers(3)
        mailbox.post(frame(0, fingers: 3))
        mailbox.post(frame(0.01, fingers: 3))
        mailbox.post(frame(0.02, fingers: 0))
        XCTAssertTrue(received.batches.isEmpty, "nothing runs on the posting thread")
        XCTAssertEqual(scheduler.pendingCount, 1, "one drain for the burst")

        scheduler.runPending()
        XCTAssertEqual(received.batches.map { $0.map(\.timestamp) }, [[0, 0.01, 0.02]])

        mailbox.post(frame(0.03, fingers: 3))
        XCTAssertEqual(scheduler.pendingCount, 1, "a drained mailbox schedules again")
        scheduler.runPending()
        XCTAssertEqual(received.batches.count, 2)
    }

    func testPointerFramesNeverCrossAndNothingCrossesWithGesturesOff() {
        let scheduler = ManualScheduler()
        let received = Received()
        let mailbox = TouchFrameMailbox(scheduler: scheduler) { received.append($0) }
        mailbox.post(frame(0, fingers: 3))
        XCTAssertEqual(scheduler.pendingCount, 0, "no gesture enabled yet")
        mailbox.setMinimumFingers(3)
        for step in 0..<50 {
            mailbox.post(frame(Double(step) * 0.01, fingers: 1))
        }
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAFullMailboxDropsTheOldestFrames() {
        let scheduler = ManualScheduler()
        let received = Received()
        let mailbox = TouchFrameMailbox(scheduler: scheduler) { received.append($0) }
        mailbox.setMinimumFingers(3)
        for step in 0..<(TouchFrameMailbox.capacity + 10) {
            mailbox.post(frame(Double(step), fingers: 3))
        }
        scheduler.runPending()
        XCTAssertEqual(received.batches.first?.count, TouchFrameMailbox.capacity)
        XCTAssertEqual(received.batches.first?.first?.timestamp, 10)
    }

    func testConcurrentPostersLoseNothingAndScheduleOneDrain() {
        let scheduler = ManualScheduler()
        let received = Received()
        let mailbox = TouchFrameMailbox(scheduler: scheduler) { received.append($0) }
        mailbox.setMinimumFingers(3)
        DispatchQueue.concurrentPerform(iterations: 4) { poster in
            for step in 0..<50 {
                mailbox.post(TouchFrame(
                    timestamp: Double(poster * 1000 + step),
                    contacts: (0..<3).map { TouchContact(id: Int32($0), x: 0.5, y: 0.5) }
                ))
            }
        }
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runPending()
        let frames = received.batches.flatMap { $0 }
        XCTAssertEqual(frames.count, 200)
        for poster in 0..<4 {
            let own = frames.map(\.timestamp).filter { Int($0) / 1000 == poster }
            XCTAssertEqual(own, own.sorted(), "each poster's frames keep their order")
        }
    }
}
