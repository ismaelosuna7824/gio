import CoreGraphics
import Foundation
import GioCore
import XCTest
@testable import GioSession

final class FakeGhostPort: CloseGhostPort, @unchecked Sendable {
    var shows: [(token: Int, frame: CGRect, duration: TimeInterval, shrink: CGFloat)] = []
    var removes: [Int] = []

    func showGhost(token: Int, image: CGImage, frame: CGRect, duration: TimeInterval, shrink: CGFloat) {
        shows.append((token, frame, duration, shrink))
    }

    func removeGhost(token: Int) {
        removes.append(token)
    }
}

final class CloseGhostControllerTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var enabled = true
        var minimized: Set<WindowID> = []
        var frames: [WindowID: CGRect] = [:]
        var cached: [WindowID: CGRect] = [:]
        var logs: [(LogLevel, String)] = []
    }

    private let viewport = CGRect(x: 0, y: 20, width: 1800, height: 1129)
    private var world: World!
    private var scheduler: ManualScheduler!
    private var port: FakeGhostPort!
    private var controller: CloseGhostController!

    override func setUp() {
        world = World()
        scheduler = ManualScheduler()
        port = FakeGhostPort()
        let world = world!
        let scheduler = scheduler!
        let viewport = viewport
        let image = Self.image()
        controller = CloseGhostController(
            context: .init(
                isEnabled: { world.enabled },
                isMinimized: { world.minimized.contains($0) },
                physicalFrame: { world.frames[$0] },
                viewports: { [viewport] },
                cachedImage: { id in world.cached[id].map { (image, $0, scheduler.now) } },
                log: { world.logs.append(($0, $1)) },
                now: { scheduler.now }
            ),
            port: port, scheduler: scheduler
        )
    }

    private static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func window(_ n: Int, x: CGFloat = 100, cached: Bool = true) -> WindowID {
        let id = WindowID(pid: pid_t(n), elementID: UInt64(n))
        let frame = CGRect(x: x, y: 200, width: 400, height: 700)
        world.frames[id] = frame
        if cached {
            world.cached[id] = frame
        }
        return id
    }

    func testClosingVisibleWindowShowsAGhostThatRemovesItself() {
        let id = window(1)

        controller.windowsClosing([id])

        XCTAssertEqual(port.shows.count, 1)
        XCTAssertEqual(port.shows[0].frame, world.frames[id])
        XCTAssertEqual(port.shows[0].duration, closeGhostDuration, accuracy: 0.001)
        XCTAssertEqual(port.shows[0].shrink, closeGhostShrink, accuracy: 0.001)
        XCTAssertEqual(controller.liveGhosts, 1)
        scheduler.advance(by: closeGhostDuration)
        XCTAssertTrue(port.removes.isEmpty, "the fade runs first")
        scheduler.advance(by: 0.2)
        XCTAssertEqual(port.removes, [port.shows[0].token])
        XCTAssertEqual(controller.liveGhosts, 0)
        XCTAssertEqual(scheduler.pendingCount, 0, "no work at rest")
    }

    func testDisabledShowsNothingAndSchedulesNothing() {
        world.enabled = false
        controller.windowsClosing([window(1)])
        XCTAssertTrue(port.shows.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testWindowWithoutAFreshImageShowsNothing() {
        let minimized = window(2)
        world.minimized = [minimized]
        controller.windowsClosing([window(1, cached: false), minimized, window(3, x: 1799)])
        XCTAssertTrue(port.shows.isEmpty)
    }

    func testAtMostFourGhostsAtOnce() {
        controller.windowsClosing((1...6).map { window($0, x: CGFloat($0) * 100) })
        XCTAssertEqual(port.shows.count, CloseGhostController.maxGhosts)
        XCTAssertEqual(Set(port.shows.map(\.token)).count, CloseGhostController.maxGhosts)
    }

    func testRemoveAllTakesEveryGhostDownAtOnce() {
        controller.windowsClosing([window(1), window(2, x: 600)])
        controller.removeAll()
        XCTAssertEqual(Set(port.removes), Set(port.shows.map(\.token)))
        XCTAssertEqual(controller.liveGhosts, 0)
        scheduler.advance(by: 1)
        XCTAssertEqual(port.removes.count, 2, "the timers find nothing left")
    }

    func testLogsNeverCarryTitles() {
        controller.windowsClosing([window(1)])
        XCTAssertTrue(world.logs.allSatisfy { !$0.1.contains("secret") })
        XCTAssertTrue(world.logs.contains { $0.1 == "close ghost id=1:1" })
    }
}
