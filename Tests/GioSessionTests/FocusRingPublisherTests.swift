import CoreGraphics
import GioCore
import XCTest
@testable import GioSession

final class FocusRingPublisherTests: XCTestCase {
    private var fixture: SessionFixture!
    private var hop: HopRecorder!
    private var delivered: Recorder<FocusRingState>!

    override func setUp() {
        fixture = SessionFixture(
            frames: [CGRect(x: 0, y: 0, width: 900, height: 1000), CGRect(x: 900, y: 0, width: 900, height: 1000)],
            focus: 0
        )
        fixture.session.config.focus.indicator = .ring
        hop = HopRecorder()
        delivered = Recorder()
    }

    private func makePublisher() -> FocusRingPublisher {
        let fixture = fixture!
        let delivered = delivered!
        return FocusRingPublisher(context: .init(
            session: { fixture.session },
            physicalFrame: { fixture.physicalFrames[$0] },
            displayFrames: { fixture.displays.allDisplays().map(\.frame) },
            isFlightActive: { fixture.flightActive },
            isZoomBusy: { fixture.zoomBusy.contains($0) },
            isFullscreen: { fixture.fullscreen.contains($0) },
            mainHop: hop.hop,
            deliver: { delivered.append($0) }
        ))
    }

    private var expectedShown: FocusRingState {
        .shown(FocusRingGeometry(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1000).insetBy(dx: -4, dy: -4), width: 4,
            color: FocusRingSectionConfig.defaultColor
        ))
    }

    func testShowsRingAroundFocusedPhysicalFrameOnMain() {
        let publisher = makePublisher()
        publisher.publish()
        XCTAssertEqual(delivered.values, [], "delivery waits for the main hop")
        hop.drain()
        XCTAssertEqual(delivered.values, [expectedShown])
    }

    func testHiddenWhenTheDimIndicatorIsConfigured() {
        fixture.session.config.focus.indicator = .dim
        XCTAssertEqual(makePublisher().snapshot(), .hidden)
    }

    func testHiddenWhenFocusedColumnIsMaximizedUnlessConfiguredOtherwise() {
        var workspace = fixture.session.manager.currentWorkspace()
        workspace.columns[0].savedWidthSpec = .standard
        fixture.session.manager.update(workspace)
        XCTAssertEqual(makePublisher().snapshot(), .hidden)
        fixture.session.config.focusRing.hideWhenMaximized = false
        XCTAssertEqual(makePublisher().snapshot(), expectedShown)
    }

    func testHiddenWhenFullscreenWithoutGap() {
        fixture.fullscreen = [fixture.focusedID!]
        XCTAssertEqual(makePublisher().snapshot(), .hidden)
    }

    func testHiddenDuringFlightAndNativeZoom() {
        let publisher = makePublisher()
        fixture.flightActive = true
        XCTAssertEqual(publisher.snapshot(), .hidden)
        fixture.flightActive = false
        fixture.zoomBusy = [fixture.focusedID!]
        XCTAssertEqual(publisher.snapshot(), .hidden)
    }

    func testHiddenWithoutPhysicalFrameOrWhenMinimized() {
        let publisher = makePublisher()
        fixture.physicalFrames = [:]
        XCTAssertEqual(publisher.snapshot(), .hidden)
    }

    func testGateDropsSubPointMovesAndMailboxCoalescesToLatest() {
        let publisher = makePublisher()
        publisher.publish()
        publisher.publish()
        XCTAssertEqual(hop.blocks.count, 1, "repeat state: no second hop")
        let id = fixture.focusedID!
        fixture.physicalFrames[id] = CGRect(x: 0.5, y: 0, width: 900, height: 1000)
        publisher.publish()
        XCTAssertEqual(hop.blocks.count, 1, "moves under 1 pt are gated")
        fixture.physicalFrames[id] = CGRect(x: 10, y: 0, width: 900, height: 1000)
        publisher.publish()
        fixture.physicalFrames[id] = CGRect(x: 20, y: 0, width: 900, height: 1000)
        publisher.publish()
        XCTAssertEqual(hop.blocks.count, 1, "one drain pending at most")
        hop.drain()
        XCTAssertEqual(delivered.values.count, 1)
        guard case .shown(let geometry) = delivered.values.last else {
            return XCTFail("expected shown")
        }
        XCTAssertEqual(geometry.frame.minX, 16, "latest frame wins (20 - width)")
    }

    func testResetGateStillDedupesAnIdenticalStateInTheMailbox() {
        let publisher = makePublisher()
        publisher.publish()
        hop.drain()
        publisher.resetGate()
        publisher.publish()
        XCTAssertEqual(hop.blocks.count, 0)
        XCTAssertEqual(delivered.values.count, 1)
    }
}
