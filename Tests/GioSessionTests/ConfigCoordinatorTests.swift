import Foundation
import GioCore
import XCTest
@testable import GioSession

/// Uses a temporary config file only; never the user's real config.
final class ConfigCoordinatorTests: XCTestCase {
    private final class World: @unchecked Sendable {
        var session = CommandSession()
        var calls: [String] = []
        var logLevels: [LogLevel] = []
        var focusFollowsMouse: [Bool] = []
        var tapObserving: Bool?
        var tapRestarts = 0
        var logs: [String] = []
    }

    private var world: World!
    private var scheduler: ManualScheduler!
    private var directory: URL!
    private var path: String!

    override func setUpWithError() throws {
        world = World()
        scheduler = ManualScheduler()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-config-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("config.toml").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator() -> ConfigCoordinator {
        let world = world!
        let path = path!
        return ConfigCoordinator(
            context: .init(
                session: { world.session },
                reloadSession: {
                    world.calls.append("reloadSession")
                    world.session.config = loadGioConfig(at: path).config
                },
                loadMessages: {
                    world.calls.append("loadMessages")
                    return loadGioConfig(at: path).messages
                },
                patchFile: { GioCore.applyConfigEdits($0, toFileAt: path) },
                applyLogLevel: {
                    world.calls.append("logLevel")
                    world.logLevels.append($0)
                },
                invalidateConfigCaches: { world.calls.append("invalidate") },
                setFocusFollowsMouse: {
                    world.calls.append("focusFollowsMouse")
                    world.focusFollowsMouse.append($0)
                },
                tapObservesMouseMoved: { world.tapObserving },
                requestTapRestart: { world.tapRestarts += 1 },
                reapplyRules: { world.calls.append("reapplyRules") },
                reflow: { world.calls.append("reflow") },
                publishSnapshot: { world.calls.append("publishSnapshot") },
                publishFocusRing: { world.calls.append("publishFocusRing") },
                log: { _, line in world.logs.append(line) }
            ),
            scheduler: scheduler
        )
    }

    private func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testReloadUpdatesTheDispatcherFromTheConfigFile() throws {
        let combo = try XCTUnwrap(parseHotkey("Ctrl+Alt+F9"))
        let coordinator = makeCoordinator()
        coordinator.refreshDispatcher()
        XCTAssertNil(coordinator.currentDispatcher().action(for: combo))
        world.calls = []
        try write("[keybindings]\n\"Ctrl+Alt+F9\" = \"center-column\"\n\n[logging]\nlevel = \"debug\"\n")

        coordinator.reloadFromApp()
        XCTAssertTrue(world.calls.isEmpty, "the reload hops onto the session queue")
        scheduler.runPending()

        XCTAssertEqual(coordinator.currentDispatcher().action(for: combo), .centerColumn)
        XCTAssertEqual(world.logLevels.last, .debug)
        XCTAssertEqual(
            world.calls,
            [
                "reloadSession", "logLevel", "invalidate", "focusFollowsMouse",
                "loadMessages", "reapplyRules", "reflow", "publishSnapshot", "publishFocusRing",
            ]
        )
        XCTAssertEqual(world.logs, ["config reloaded from the app"])
    }

    func testReloadKeepsTheConfigMessages() throws {
        try write("[layout]\nnot-a-key = 3\n")
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.messages.isEmpty)
        coordinator.reloadFromApp()
        scheduler.runPending()
        XCTAssertFalse(coordinator.messages.isEmpty)
        coordinator.setMessages(["launch"])
        XCTAssertEqual(coordinator.messages, ["launch"])
    }

    func testInvalidEditsDoNotWriteOrReload() throws {
        let original = "[behavior]\nfocus-follows-mouse = false\n"
        try write(original)
        let coordinator = makeCoordinator()

        let result = coordinator.applyConfigEdits([
            .set(table: "layout", key: "gaps", value: .string("not a number")),
        ])

        guard case .failure = result else {
            return XCTFail("an invalid value must be rejected")
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
        XCTAssertEqual(scheduler.pendingCount, 0, "a rejected edit reloads nothing")
        XCTAssertTrue(world.calls.isEmpty)
    }

    func testValidEditWritesThenReloadsOnTheQueue() throws {
        try write("[behavior]\nfocus-follows-mouse = false\n")
        let coordinator = makeCoordinator()

        let result = coordinator.applyConfigEdits(
            behaviorEdits(focusFollowsMouse: true, mouseFollowsFocus: true, moveCrossesMonitorAtEdge: false)
        )

        guard case .success = result else {
            return XCTFail("a valid edit is written")
        }
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("focus-follows-mouse = true"))
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(world.calls.isEmpty, "the live reload waits for the session queue")
        scheduler.runPending()
        XCTAssertEqual(world.calls.first, "reloadSession")
        XCTAssertEqual(world.focusFollowsMouse, [true])
        XCTAssertEqual(world.logs, ["config edited from the app and reloaded"])
    }

    func testFocusFollowsMouseChangeRequestsATapRestart() {
        let coordinator = makeCoordinator()
        world.tapObserving = false
        world.session.config.behavior.focusFollowsMouse = true
        coordinator.refreshDispatcher()
        XCTAssertEqual(world.tapRestarts, 1)
        XCTAssertEqual(world.focusFollowsMouse, [true])

        // The tap already observes moves: nothing to rebuild.
        world.tapObserving = true
        coordinator.refreshDispatcher()
        XCTAssertEqual(world.tapRestarts, 1)

        // Turned off again while the tap observes moves.
        world.session.config.behavior.focusFollowsMouse = false
        coordinator.refreshDispatcher()
        XCTAssertEqual(world.tapRestarts, 2)
    }

    func testNoTapMeansNoRestart() {
        let coordinator = makeCoordinator()
        world.tapObserving = nil
        world.session.config.behavior.focusFollowsMouse = true
        coordinator.refreshDispatcher()
        XCTAssertEqual(world.tapRestarts, 0)
        XCTAssertEqual(world.focusFollowsMouse, [true])
    }

    func testDispatcherIsReadableFromAnotherThread() throws {
        let combo = try XCTUnwrap(parseHotkey("Ctrl+Alt+F9"))
        world.session.config.keybindings = [(combo, .maximizeColumn)]
        let coordinator = makeCoordinator()
        coordinator.refreshDispatcher()
        let done = expectation(description: "read")
        DispatchQueue.global().async {
            XCTAssertEqual(coordinator.currentDispatcher().action(for: combo), .maximizeColumn)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
