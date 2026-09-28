import XCTest
@testable import GioCore

/// Plan §21: command parsing, in-process dispatch, single-instance lock.
/// The `gio` executable itself lands with IPC (RW-17).
final class CommandDispatcherTests: XCTestCase {
    func testParseAllVerbs() throws {
        XCTAssertEqual(try parseCLICommand(["reload"]).get(), .reload)
        XCTAssertEqual(try parseCLICommand(["restart"]).get(), .restart)
        XCTAssertEqual(try parseCLICommand(["list-windows"]).get(), .listWindows)
        XCTAssertEqual(try parseCLICommand(["list-workspaces"]).get(), .listWorkspaces)
        XCTAssertEqual(try parseCLICommand(["focus", "left"]).get(), .focus(.left))
        XCTAssertEqual(try parseCLICommand(["move", "down"]).get(), .move(.down))
        XCTAssertEqual(try parseCLICommand(["workspace", "3"]).get(), .workspace(3))
        XCTAssertEqual(try parseCLICommand(["layout", "info"]).get(), .layoutInfo)
        XCTAssertEqual(try parseCLICommand(["help"]).get(), .help)
    }

    func testParseRejectsJunk() {
        XCTAssertEqual(
            parseCLICommand([]).mapError { $0 }.failure, .noArguments
        )
        XCTAssertEqual(
            parseCLICommand(["frobnicate"]).mapError { $0 }.failure,
            .unknownCommand("frobnicate")
        )
        XCTAssertEqual(
            parseCLICommand(["focus"]).mapError { $0 }.failure,
            .missingArgument(name: "left|right|up|down", command: "focus")
        )
        XCTAssertEqual(
            parseCLICommand(["focus", "sideways"]).mapError { $0 }.failure,
            .missingArgument(name: "left|right|up|down", command: "focus")
        )
        XCTAssertEqual(
            parseCLICommand(["workspace", "42"]).mapError { $0 }.failure,
            .invalidWorkspace("42")
        )
        XCTAssertEqual(
            parseCLICommand(["layout", "fancy"]).mapError { $0 }.failure,
            .missingArgument(name: "info", command: "layout")
        )
    }

    func testDispatchWorkspaceAndLists() {
        var session = CommandSession()
        XCTAssertEqual(dispatch(.workspace(4), session: &session), "switched to workspace 4")
        XCTAssertEqual(session.manager.current, 4)
        XCTAssertEqual(
            dispatch(.workspace(42), session: &session), "invalid workspace (1...9)"
        )
        let list = dispatch(.listWorkspaces, session: &session)
        XCTAssertTrue(list.contains("workspaces current=4"))
        XCTAssertTrue(list.contains("*4 columns=0"))
        XCTAssertEqual(dispatch(.listWindows, session: &session), "windows=0")
        XCTAssertTrue(dispatch(.layoutInfo, session: &session).contains("columns=0"))
    }

    func testDispatchFocusAndMove() throws {
        var session = CommandSession()
        let registry = session.registry
        let window = ManagedWindow(
            id: WindowID(pid: 1, elementID: 1), pid: 1, application: "A", title: "a",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .tiled
        )
        try registry.register(window)
        var first = session.manager.workspace(1)!
        first.columns = [Column(id: ColumnID(1), width: 300, windows: [window.id])]
        first.focusedWindow = window.id
        session.manager.update(first)
        XCTAssertTrue(dispatch(.focus(.right), session: &session).contains("unchanged"))
        XCTAssertTrue(dispatch(.move(.left), session: &session).contains("moved column=0"))
        XCTAssertTrue(dispatch(.help, session: &session).contains("gio focus"))
        XCTAssertTrue(dispatch(.restart, session: &session).contains("daemon"))
    }

    func testSingleInstanceLock() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-lock-test-\(UUID().uuidString).lock").path
        let first = SingleInstanceLock()
        let second = SingleInstanceLock()
        XCTAssertTrue(first.acquire(path: path))
        XCTAssertFalse(second.acquire(path: path))
        first.release()
        XCTAssertTrue(second.acquire(path: path))
        second.release()
        XCTAssertTrue(defaultLockPath().hasSuffix(".config/gio/gio.lock"))
    }
}

private extension Result where Failure == CLICommandError {
    var failure: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
