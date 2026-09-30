import Foundation
import GioCore
import XCTest
@testable import GioSession

final class IPCRouterTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var focused: WindowID? = WindowID(pid: 5, elementID: 1)
        var dispatched: [[String]] = []
        var calls: [String] = []
        var intents: [(Bool, WindowID?)] = []
        var mainBlocks: [(TimeInterval, @Sendable () -> Void)] = []
        var restarts = 0
        var logs: [String] = []
    }

    private var world: World!

    override func setUp() {
        world = World()
    }

    /// The dispatch is faked: no real config is read (the live one runs
    /// `dispatchIPC`, whose `reload` reads the user's config file).
    private func makeRouter() -> IPCRouter {
        let world = world!
        return IPCRouter(context: .init(
            focusedWindow: { world.focused },
            dispatch: { argv in
                world.dispatched.append(argv)
                world.calls.append("dispatch")
                if case .failure(let error) = parseCLICommand(argv) {
                    return IPCResponse(ok: false, error: String(describing: error))
                }
                return IPCResponse(ok: true, output: "ok \(argv.joined(separator: " "))")
            },
            applyReloadedConfig: { world.calls.append("applyReloadedConfig") },
            requestFocusIntent: { carries, previous in
                world.calls.append("focusIntent")
                world.intents.append((carries, previous))
            },
            reflow: { world.calls.append("reflow") },
            publishBar: { world.calls.append("publishBar") },
            mainAfter: { delay, block in world.mainBlocks.append((delay, block)) },
            restart: { world.restarts += 1 },
            log: { _, line in world.logs.append(line) }
        ))
    }

    func testStatusOnlyDispatchesAndPublishesTheBar() {
        let response = makeRouter().handle(["status"])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(world.dispatched, [["status"]])
        XCTAssertEqual(world.calls, ["dispatch", "publishBar"])
        XCTAssertTrue(world.mainBlocks.isEmpty)
    }

    func testReloadAppliesTheReloadedConfig() {
        let response = makeRouter().handle(["reload"])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(world.calls, ["dispatch", "applyReloadedConfig", "publishBar"])
    }

    func testRestartRunsOnMainAfterTheReply() {
        let router = makeRouter()
        let response = router.handle(["restart"])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(world.calls, ["dispatch", "publishBar"])
        XCTAssertEqual(world.logs, ["restart requested over IPC"])
        XCTAssertEqual(world.mainBlocks.count, 1)
        XCTAssertEqual(world.mainBlocks.first?.0, IPCRouter.restartDelay)
        XCTAssertEqual(IPCRouter.restartDelay, 0.3)
        XCTAssertEqual(world.restarts, 0, "nothing restarts before the reply left")
        world.mainBlocks.first?.1()
        XCTAssertEqual(world.restarts, 1)
        withExtendedLifetime(router) {}
    }

    func testFocusCommandsCarryIntentWithThePreviousFocusAndReflow() {
        let previous = world.focused
        let router = makeRouter()
        for argv in [["focus", "left"], ["move", "right"], ["workspace", "2"]] {
            world.calls = []
            router.handle(argv)
            XCTAssertEqual(world.calls, ["dispatch", "focusIntent", "reflow", "publishBar"], "\(argv)")
        }
        XCTAssertEqual(world.intents.map(\.0), [true, true, true])
        XCTAssertEqual(world.intents.map(\.1), [previous, previous, previous])
    }

    func testPreviousFocusIsReadBeforeTheDispatch() {
        let before = world.focused
        let world = world!
        let router = IPCRouter(context: .init(
            focusedWindow: { world.focused },
            dispatch: { _ in
                world.focused = WindowID(pid: 9, elementID: 2)
                return IPCResponse(ok: true, output: "")
            },
            applyReloadedConfig: {}, requestFocusIntent: { world.intents.append(($0, $1)) },
            reflow: {}, publishBar: {}, mainAfter: { _, _ in }, restart: {}, log: { _, _ in }
        ))
        router.handle(["focus", "right"])
        XCTAssertEqual(world.intents.first?.1, before)
    }

    func testUnparsableArgvOnlyPublishesTheBar() {
        let response = makeRouter().handle(["bogus"])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(world.calls, ["dispatch", "publishBar"])
    }
}
