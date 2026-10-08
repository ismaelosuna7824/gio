import AppKit
import GioCore
import XCTest
@testable import GioUI

/// SM-12: the display link that counts presented frames exists only while a
/// flight is on screen; every exit invalidates it.
@MainActor
final class FlightFrameLinkTests: XCTestCase {
    private final class FakeHandle: FrameLinkHandle {
        var invalidated = 0

        func invalidate() {
            invalidated += 1
        }
    }

    private var made: [FakeHandle] = []
    private var supported = true

    private func makeLink() -> FlightFrameLink {
        FlightFrameLink { [unowned self] _, _ in
            guard supported else {
                return nil
            }
            let handle = FakeHandle()
            made.append(handle)
            return handle
        }
    }

    private let view = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    func testNoLinkAtRest() {
        let link = makeLink()
        XCTAssertFalse(link.isRunning)
        XCTAssertTrue(made.isEmpty, "nothing is created before a flight flies")
        link.frame(at: 1)
        XCTAssertNil(link.finish(at: 2))
    }

    func testOneLinkPerFlightCountingUntilTheFlightLands() {
        let link = makeLink()
        link.start(on: view, refreshRate: 60, at: 10)
        link.retargeted(on: view, refreshRate: 60, at: 10.01)
        XCTAssertEqual(made.count, 1, "a retarget keeps the running link")
        XCTAssertTrue(link.isRunning)
        link.frame(at: 10)
        link.frame(at: 10 + 1.0 / 60)
        link.frame(at: 10 + 2.0 / 60)
        let stats = link.finish(at: 10 + 3.0 / 60)
        XCTAssertEqual(stats?.presented, 2)
        XCTAssertEqual(stats?.expected, 3)
        XCTAssertEqual(made.first?.invalidated, 1)
        XCTAssertFalse(link.isRunning, "no link once the flight landed")
    }

    func testARetargetAfterTheDeadlineFinishedTheLinkMeasuresAgain() {
        let link = makeLink()
        link.start(on: view, refreshRate: 60, at: 10)
        link.frame(at: 10)
        link.frame(at: 10 + 1.0 / 60)
        XCTAssertNotNil(link.finish(at: 10 + 1.0 / 60), "the deadline of the previous token")
        // SM-13: a retarget already queued for the same flight arrives now.
        link.retargeted(on: view, refreshRate: 60, at: 11)
        XCTAssertTrue(link.isRunning)
        XCTAssertEqual(made.count, 2)
        link.frame(at: 11)
        link.frame(at: 11 + 1.0 / 60)
        link.frame(at: 11 + 2.0 / 60)
        let stats = link.finish(at: 11 + 2.0 / 60)
        XCTAssertEqual(stats?.presented, 2, "the retargeted flight is measured, not reported as frames=0")
        XCTAssertEqual(stats?.expected, 2)
    }

    func testCancelEndsTheLinkWithoutStats() {
        let link = makeLink()
        link.start(on: view, refreshRate: 120, at: 0)
        link.cancel()
        XCTAssertEqual(made.first?.invalidated, 1)
        XCTAssertFalse(link.isRunning)
        XCTAssertNil(link.finish(at: 1))
        link.cancel()
        XCTAssertEqual(made.first?.invalidated, 1, "cancel at rest touches nothing")
    }

    func testWithoutADisplayLinkNothingIsMeasured() {
        supported = false
        let link = makeLink()
        link.start(on: view, refreshRate: 60, at: 0)
        XCTAssertFalse(link.isRunning)
        link.frame(at: 0.1)
        XCTAssertNil(link.finish(at: 0.2), "macOS 13: no link, no numbers")
    }
}
