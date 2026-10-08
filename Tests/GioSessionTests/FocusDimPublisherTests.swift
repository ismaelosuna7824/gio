import CoreGraphics
import GioCore
import XCTest
@testable import GioSession

final class FocusDimPublisherTests: XCTestCase {
    private let left = CGRect(x: 0, y: 0, width: 900, height: 1000)
    private let right = CGRect(x: 900, y: 0, width: 900, height: 1000)
    private var fixture: SessionFixture!
    private var probe: StubSystemProbe!
    private var scheduler: ManualScheduler!
    private var hop: HopRecorder!
    private var delivered: Recorder<FocusDimState>!

    override func setUp() {
        fixture = SessionFixture(frames: [left, right], focus: 0)
        probe = StubSystemProbe()
        probe.serverWindows = [ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: right)]
        scheduler = ManualScheduler()
        hop = HopRecorder()
        delivered = Recorder()
    }

    private func makePublisher() -> FocusDimPublisher {
        let fixture = fixture!
        let probe = probe!
        let delivered = delivered!
        return FocusDimPublisher(
            context: .init(
                session: { fixture.session },
                physicalFrame: { fixture.physicalFrames[$0] },
                displays: { fixture.displays.allDisplays() },
                isMotionActive: { fixture.motionActive },
                isFlightActive: { fixture.flightActive },
                isNativeZoomActive: { fixture.zoomActive },
                isMouseDown: { probe.isMouseDown },
                isShuttingDown: { fixture.shuttingDown },
                frontToBack: { probe.windowServerWindows(displayHeight: 1169) },
                mainHop: hop.hop,
                deliver: { delivered.append($0) }
            ),
            scheduler: scheduler
        )
    }

    private func settle() {
        scheduler.advance(by: 0.05)
        hop.drain()
    }

    private var isShown: Bool {
        if case .shown? = delivered.values.last {
            return true
        }
        return false
    }

    func testUpdatesCoalesceIntoOneRecomputeAfter50ms() {
        let publisher = makePublisher()
        publisher.update()
        publisher.update()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: 0.049)
        XCTAssertEqual(probe.serverQueries, 0)
        settle()
        XCTAssertEqual(probe.serverQueries, 1, "one WindowServer query")
        XCTAssertTrue(isShown)
    }

    func testDisabledIndicatorHidesWithoutAnyQuery() {
        fixture.session.config.focus.indicator = .ring
        let publisher = makePublisher()
        publisher.update()
        hop.drain()
        XCTAssertEqual(delivered.values, [.hidden(.disabled)])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testHiddenAtOnceDuringMotionFlightAndZoom() {
        let publisher = makePublisher()
        fixture.motionActive = true
        publisher.update()
        hop.drain()
        fixture.motionActive = false
        fixture.flightActive = true
        publisher.update()
        hop.drain()
        fixture.flightActive = false
        fixture.zoomActive = true
        publisher.update()
        hop.drain()
        XCTAssertEqual(delivered.values, [.hidden(.motion), .hidden(.flight), .hidden(.zoom)], "equal states are deduplicated")
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testMotionStartedBeforeTheRecomputeHidesInsteadOfQuerying() {
        let publisher = makePublisher()
        publisher.update()
        fixture.motionActive = true
        settle()
        XCTAssertEqual(delivered.values, [.hidden(.motion)])
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testDragHoldHidesUntilReleased() {
        let publisher = makePublisher()
        publisher.holdForDrag()
        XCTAssertTrue(publisher.isDragHeld)
        hop.drain()
        XCTAssertEqual(delivered.values, [.hidden(.drag)])
        publisher.update()
        settle()
        XCTAssertEqual(delivered.values, [.hidden(.drag)])
        publisher.releaseDragHold()
        publisher.update()
        settle()
        XCTAssertTrue(isShown)
    }

    func testMouseDownRetriesAndComputesAfterRelease() {
        let publisher = makePublisher()
        probe.pressedMouseButtons = 1
        publisher.update()
        settle()
        XCTAssertEqual(probe.serverQueries, 0)
        XCTAssertEqual(scheduler.pendingCount, 1, "retry scheduled")
        probe.pressedMouseButtons = 0
        settle()
        XCTAssertEqual(probe.serverQueries, 1)
        XCTAssertTrue(isShown)
    }

    func testShutdownSkipsThePendingRecompute() {
        let publisher = makePublisher()
        publisher.update()
        fixture.shuttingDown = true
        settle()
        XCTAssertEqual(delivered.values, [])
        XCTAssertEqual(probe.serverQueries, 0)
    }

    func testNoFocusedWindowHides() {
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.focusedWindow = nil
        fixture.session.manager.update(workspace)
        let publisher = makePublisher()
        publisher.update()
        settle()
        XCTAssertEqual(delivered.values, [.hidden(.noFocus)])
    }

    func testOnlyUnfocusedVisibleTiledWindowsAreDimmed() {
        let publisher = makePublisher()
        publisher.update()
        settle()
        guard case .shown(let regions, let strength)? = delivered.values.last else {
            return XCTFail("expected shown")
        }
        XCTAssertEqual(strength, fixture.session.config.focus.dimStrength)
        XCTAssertEqual(regions.flatMap(\.windows).map(\.bounds), [right])
    }

    /// SM-08: at the end of a flight the dim is computed at once (no 50 ms
    /// coalescing) so the live dim is up in the frame the overlay leaves.
    func testPublishNowComputesWithoutWaitingForTheCoalescedRecompute() {
        let publisher = makePublisher()
        fixture.flightActive = true
        publisher.update()
        hop.drain()
        XCTAssertEqual(delivered.values, [.hidden(.flight)])
        fixture.flightActive = false
        publisher.publishNow()
        XCTAssertEqual(probe.serverQueries, 1, "queried on the session queue right away")
        hop.drain()
        XCTAssertTrue(isShown)
        XCTAssertEqual(scheduler.pendingCount, 0, "no recompute left behind")
        fixture.motionActive = true
        publisher.publishNow()
        hop.drain()
        XCTAssertEqual(delivered.values.last, .hidden(.motion), "the timing rule still applies")
    }
}
