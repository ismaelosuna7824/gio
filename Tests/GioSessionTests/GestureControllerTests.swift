import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

/// TG-03: the session side of trackpad gestures: recognized swipes move the
/// strip through the reconciler's sink (the apps' Accessibility motion
/// lanes) while the fingers are down; the release commits State and hands
/// the velocity to the settle; an extra finger or a mouse button abandons;
/// vertical swipes map to actions.
final class GestureControllerTests: XCTestCase {
    private final class Sink: MotionFrameSink {
        var laneWrites: [(pid: pid_t, writes: [MotionWrite])] = []

        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            laneWrites.append((pid, writes))
            return true
        }

        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    private final class World: @unchecked Sendable {
        var settings = GesturesSectionConfig()
        var mouseDown = false
        var manager = WorkspaceManager()
        var hasSurface = true
        var physical: [WindowID: CGRect] = [:]
        var calls: [String] = []
        var releases: [GestureRelease] = []
        var abandons: [GestureAbandon] = []
        var actions: [HotkeyAction] = []
        var overviews = 0
        var sampled: [WindowID: CGRect] = [:]
        var unverified: [WindowID] = []
        var ringPublishes = 0
        var logs: [String] = []
        var transport = GestureTransport.accessibility(reason: .renderer, missing: [])
        var holds: [(frames: [WindowID: CGRect], display: CGRect)] = []
        var tracks: [[WindowID: CGRect]] = []
        var lost: (() -> Void)?
        var now: TimeInterval = 0
        var drawn: [WindowID: CGRect] = [:]
        let sink = Sink()
    }

    private let display = DisplayID(1)
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let engine = ScrollableLayoutEngine(config: LayoutConfig(padding: 8, gap: 8))
    private var world: World!
    private var controller: GestureController!

    private func id(_ n: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: n)
    }

    /// Four 600 pt columns (content 0...2440, offset 0...1440), focus on the first.
    override func setUp() {
        world = World()
        world.manager.syncDisplays([display])
        var workspace = world.manager.currentWorkspace()
        workspace.columns = (1...4).map { Column(id: ColumnID(UInt64($0)), width: 600, windows: [id(UInt64($0))]) }
        workspace.focusedColumn = 0
        workspace.focusedWindow = id(1)
        world.manager.update(workspace)
        let plan = gestureFrames(surface()!, offset: 0)!
        world.physical = plan.visible.merging(plan.parked.mapValues(\.frame)) { first, _ in first }
        let world = world!
        controller = GestureController(context: .init(
            settings: { world.settings },
            isMouseDown: { world.mouseDown },
            surface: { [unowned self] in world.hasSurface ? surface() : nil },
            physicalFrames: { world.physical },
            sink: { world.sink },
            updateManager: { body in body(&world.manager) },
            beginTracking: { world.calls.append("begin") },
            holdOverlay: { frames, display, lost in
                world.holds.append((frames, display))
                world.lost = lost
                return world.transport
            },
            trackOverlay: { world.tracks.append($0) },
            overlayFrames: { world.drawn },
            recordSampled: { id, frame, _ in
                world.sampled[id] = frame
                world.physical[id] = frame
            },
            markUnverified: { world.unverified.append($0) },
            focusedWindow: { world.manager.currentWorkspace().focusedWindow },
            publishFocusRing: { world.ringPublishes += 1 },
            settle: { world.releases.append($0) },
            abandon: { world.abandons.append($0) },
            perform: { world.actions.append($0) },
            toggleOverview: { world.overviews += 1 },
            log: { _, line in world.logs.append(line) },
            now: { world.now }
        ))
    }

    private func surface() -> GestureSurface? {
        let workspace = world.manager.currentWorkspace()
        return GestureSurface(
            display: display, workspace: workspace, modes: [:], engine: engine,
            viewport: viewport, displayFrame: viewport, otherDisplays: [], centering: false
        )
    }

    private func frame(_ t: TimeInterval, fingers: Int, x: Double, y: Double = 0.5) -> TouchFrame {
        TouchFrame(timestamp: t, contacts: (0..<fingers).map { TouchContact(id: Int32($0), x: x, y: y) })
    }

    /// Three fingers from x 0.5 leftwards in `steps` steps of 0.05, 10 ms apart.
    private func swipeLeft(steps: Int) -> [TouchFrame] {
        (0...steps).map { frame(Double($0) * 0.01, fingers: 3, x: 0.5 - Double($0) * 0.05) }
    }

    func testTheStripFollowsTheFingersThroughTheSink() {
        controller.deliver(swipeLeft(steps: 1))
        XCTAssertEqual(world.calls, ["begin"], "the running motion and overlay stop once")
        XCTAssertTrue(controller.isTracking)
        // Natural: 0.05 of the trackpad to the left scrolls 50 pt to the right.
        XCTAssertEqual(world.sampled[id(1)]?.minX, -42)
        XCTAssertEqual(world.sampled[id(2)]?.minX, 566)
        XCTAssertEqual(world.sink.laneWrites.count, 1, "one submission to the app's lane for the drain")
        XCTAssertEqual(world.sink.laneWrites.first?.pid, 10)
        XCTAssertEqual(Set(world.sink.laneWrites.flatMap(\.writes).map(\.id)), [id(1), id(2)])
        XCTAssertEqual(Set(world.unverified), [id(1), id(2)])
        XCTAssertEqual(controller.animatingPids, [10])
        XCTAssertEqual(world.ringPublishes, 1, "the ring follows the focused window")
        XCTAssertEqual(world.manager.currentWorkspace().viewportOffset, 0, "State does not move while the fingers do")
    }

    func testReleaseCommitsStateAndHandsTheVelocityToTheSettle() throws {
        controller.deliver(swipeLeft(steps: 6) + [frame(0.07, fingers: 2, x: 0.2)])
        XCTAssertFalse(controller.isTracking)
        // 0.3 of the trackpad in 70 ms: 4286 pt/s, projected past the end.
        let release = try XCTUnwrap(world.releases.first)
        XCTAssertEqual(release.velocity, -4285.7, accuracy: 0.1, "windows move left")
        XCTAssertEqual(release.windows, [id(1), id(2), id(3), id(4)])
        XCTAssertTrue(release.focusChanged)
        let workspace = world.manager.currentWorkspace()
        XCTAssertEqual(workspace.viewportOffset, 1440)
        XCTAssertEqual(workspace.focusedColumn, 3)
        XCTAssertEqual(workspace.focusedWindow, id(4))
        XCTAssertTrue(world.logs.contains { $0.hasPrefix("gesture scroll end") })
    }

    func testASlowReleaseSnapsBackToTheNearestEdgeWithoutChangingFocus() throws {
        // 0.05 to the left, a rest, then lift: 50 pt, no velocity, back to 0.
        controller.deliver(swipeLeft(steps: 1) + [frame(0.2, fingers: 3, x: 0.45), frame(0.3, fingers: 0, x: 0)])
        let release = try XCTUnwrap(world.releases.first)
        XCTAssertEqual(release.velocity, 0)
        XCTAssertEqual(world.manager.currentWorkspace().viewportOffset, 0)
        XCTAssertEqual(world.manager.currentWorkspace().focusedWindow, id(1))
        XCTAssertFalse(release.focusChanged)
    }

    func testAnExtraFingerAbandonsWithoutTouchingState() {
        controller.deliver(swipeLeft(steps: 3) + [frame(0.04, fingers: 4, x: 0.35)])
        XCTAssertEqual(world.abandons, [.cancelled])
        XCTAssertTrue(world.releases.isEmpty)
        XCTAssertFalse(controller.isTracking)
        XCTAssertEqual(world.manager.currentWorkspace().viewportOffset, 0)
    }

    func testAMouseButtonAbandonsTheGesture() {
        controller.deliver(swipeLeft(steps: 1))
        world.mouseDown = true
        controller.deliver([frame(0.02, fingers: 3, x: 0.3), frame(0.03, fingers: 0, x: 0)])
        XCTAssertEqual(world.abandons, [.mouse])
        XCTAssertTrue(world.releases.isEmpty, "the later lift is not a release")
        XCTAssertFalse(controller.isTracking)
    }

    func testNoStripMeansNoGesture() {
        world.hasSurface = false
        controller.deliver(swipeLeft(steps: 3) + [frame(0.04, fingers: 0, x: 0)])
        XCTAssertEqual(world.calls, [])
        XCTAssertTrue(world.sink.laneWrites.isEmpty)
        XCTAssertTrue(world.releases.isEmpty)
    }

    func testDisabledScrollIgnoresHorizontalSwipes() {
        world.settings.scroll = false
        controller.deliver(swipeLeft(steps: 3))
        XCTAssertEqual(world.calls, [])
    }

    func testVerticalSwipesSwitchWorkspacesAndToggleTheOverview() {
        controller.deliver([frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.4), frame(0.02, fingers: 0, x: 0)])
        XCTAssertEqual(world.actions, [.focusWorkspaceDown], "natural: swiping up shows the workspace below")
        world.settings.natural = false
        controller.deliver([frame(0.1, fingers: 3, x: 0.5, y: 0.3), frame(0.11, fingers: 3, x: 0.5, y: 0.4), frame(0.12, fingers: 0, x: 0)])
        XCTAssertEqual(world.actions.last, .focusWorkspaceUp)

        world.settings.overview = true
        controller.deliver([frame(0.2, fingers: 4, x: 0.5, y: 0.3), frame(0.21, fingers: 4, x: 0.5, y: 0.4), frame(0.22, fingers: 0, x: 0)])
        XCTAssertEqual(world.overviews, 1)
        controller.deliver([frame(0.3, fingers: 4, x: 0.5, y: 0.4), frame(0.31, fingers: 4, x: 0.5, y: 0.3), frame(0.32, fingers: 0, x: 0)])
        XCTAssertEqual(world.overviews, 1, "only a swipe up toggles the overview")
        XCTAssertEqual(world.actions.count, 2)
    }

    func testTheFirstContactFrameIsLoggedOnce() {
        controller.deliver([frame(0, fingers: 3, x: 0.5)])
        controller.deliver([frame(0.01, fingers: 3, x: 0.5)])
        XCTAssertEqual(world.logs.filter { $0.hasPrefix("gestures first contact frame") }.count, 1)
    }

    // MARK: TG-07 the overlay under the fingers

    private var strip: [WindowID] {
        [id(1), id(2), id(3), id(4)]
    }

    func testUnderTheOverlayTheFingersMoveTheLayersAndNoWindowIsWritten() throws {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 1))
        XCTAssertEqual(world.holds.count, 1)
        let hold = try XCTUnwrap(world.holds.first)
        XCTAssertEqual(hold.display, viewport)
        XCTAssertEqual(Set(hold.frames.keys), Set(strip), "visible and parked columns alike")
        XCTAssertEqual(hold.frames[id(1)]?.minX, 8, "held where the windows are")
        let tracked = try XCTUnwrap(world.tracks.last)
        XCTAssertEqual(try XCTUnwrap(tracked[id(1)]).minX, -42, accuracy: 1e-6, "layers are not rounded to whole points")
        XCTAssertEqual(try XCTUnwrap(tracked[id(2)]).minX, 566, accuracy: 1e-6)
        XCTAssertTrue(world.sink.laneWrites.isEmpty, "nothing reaches Accessibility while the fingers move")
        XCTAssertTrue(world.sampled.isEmpty, "no physical frame claims a write that did not happen")
        XCTAssertTrue(world.unverified.isEmpty)
        XCTAssertEqual(controller.animatingPids, [])
        XCTAssertEqual(world.ringPublishes, 0, "the overlay draws the ring with its layer")
        XCTAssertTrue(world.logs.contains { $0.hasPrefix("gesture scroll begin") && $0.hasSuffix("transport=overlay") })
    }

    func testTheAccessibilityPumpIsTheFallbackTransport() {
        controller.deliver(swipeLeft(steps: 1))
        XCTAssertEqual(world.holds.count, 1, "the overlay is asked first")
        XCTAssertTrue(world.tracks.isEmpty)
        XCTAssertEqual(world.sampled[id(1)]?.minX, -42)
        XCTAssertTrue(world.logs.contains { $0.hasPrefix("gesture scroll begin") && $0.hasSuffix("transport=ax") })
    }

    func testASwipeCatchingAnOverlayFlightStartsWhereItsLayersAreDrawn() throws {
        world.drawn = world.physical.mapValues { $0.offsetBy(dx: -300, dy: 0) }
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 1))
        let hold = try XCTUnwrap(world.holds.first)
        XCTAssertEqual(hold.frames[id(1)]?.minX, -292, "held where the running layers are, not where the windows landed")
        let tracked = try XCTUnwrap(world.tracks.last?[id(1)])
        XCTAssertEqual(tracked.minX, -342, accuracy: 1e-6, "the offset continues from what is drawn")
    }

    func testThePumpStartsFromTheRealWindowsWhileTheOffsetFollowsTheDrawnStrip() {
        world.drawn = world.physical.mapValues { $0.offsetBy(dx: -300, dy: 0) }
        controller.deliver(swipeLeft(steps: 1))
        XCTAssertEqual(world.sampled[id(1)]?.minX, -342, "written: the real window is still at its landing")
        XCTAssertTrue(world.logs.contains { $0.hasPrefix("gesture scroll begin") && $0.contains("offset=300") })
    }

    func testAReleaseUnderTheOverlayCommitsStateAndHandsTheVelocityToTheSettle() throws {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 6) + [frame(0.07, fingers: 2, x: 0.2)])
        let release = try XCTUnwrap(world.releases.first)
        XCTAssertEqual(release.velocity, -4285.7, accuracy: 0.1)
        XCTAssertEqual(release.windows, Set(strip))
        XCTAssertEqual(world.manager.currentWorkspace().viewportOffset, 1440)
        let last = try XCTUnwrap(world.tracks.last?[id(1)])
        XCTAssertEqual(last.minX, -292, accuracy: 1e-6, "the settle starts from the layers' last frames")
        XCTAssertTrue(world.sink.laneWrites.isEmpty)
        XCTAssertFalse(controller.isTracking)
    }

    func testALostOverlayHandsTheScrollToThePumpAtTheCurrentOffset() {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 2))
        let tracked = world.tracks.count
        XCTAssertTrue(world.sink.laneWrites.isEmpty)

        world.lost?()
        XCTAssertEqual(world.sampled[id(1)]?.minX, -92, "from the offset the fingers reached")
        XCTAssertEqual(controller.animatingPids, [10])
        XCTAssertTrue(world.logs.contains("gesture scroll transport=ax reason=overlay-lost"))

        controller.deliver([frame(0.03, fingers: 3, x: 0.35)])
        XCTAssertEqual(world.sampled[id(1)]?.minX, -142)
        XCTAssertEqual(world.tracks.count, tracked, "the overlay is not fed any more")
    }

    func testALostOverlayWithAButtonDownAbandonsTheScroll() {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 1))
        world.mouseDown = true
        world.lost?()
        XCTAssertEqual(world.abandons, [.mouse])
        XCTAssertTrue(world.sink.laneWrites.isEmpty)
        XCTAssertFalse(controller.isTracking)
    }

    func testTheLossOfAnEarlierScrollsOverlayChangesNothing() {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 1) + [frame(0.02, fingers: 0, x: 0)])
        let stale = world.lost
        controller.deliver((0...1).map { frame(1 + Double($0) * 0.01, fingers: 3, x: 0.5 - Double($0) * 0.05) })
        XCTAssertEqual(world.holds.count, 2)
        stale?()
        XCTAssertTrue(world.sink.laneWrites.isEmpty)
        XCTAssertTrue(controller.isTracking)
    }

    func testRestingFingersKeepTheOverlayAlive() {
        world.transport = .overlay(layers: strip)
        controller.deliver(swipeLeft(steps: 1))
        let tracked = world.tracks.count
        world.now = gestureOverlayKeepAlive / 2
        controller.deliver([frame(0.3, fingers: 3, x: 0.45)])
        XCTAssertEqual(world.tracks.count, tracked, "nothing moved, nothing sent")
        world.now = gestureOverlayKeepAlive
        controller.deliver([frame(0.6, fingers: 3, x: 0.45)])
        XCTAssertEqual(world.tracks.count, tracked + 1)
        XCTAssertEqual(world.tracks.last, [:], "an empty update only re-arms the overlay's watchdog")
        XCTAssertTrue(controller.isTracking)
    }
}
