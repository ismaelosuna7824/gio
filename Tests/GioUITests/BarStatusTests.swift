import GioCore
import XCTest
@testable import GioUI

/// Bar state parsing and title rendering. The AppKit shell (status item,
/// menu, timer) is thin and live-only by design.
final class BarStatusTests: XCTestCase {
    func testParseValidStatus() {
        let state = parseBarStatus(
            #"{"columns":3,"focusedWindow":"7:3","workspace":2,"windows":5}"#
        )
        XCTAssertEqual(state, BarSessionState(workspace: 2, windows: 5, columns: 3, hasFocusedWindow: true))
    }

    func testParseToleratesMissingOptionals() {
        let state = parseBarStatus(#"{"columns":0,"workspace":1}"#)
        XCTAssertEqual(state, BarSessionState(workspace: 1, windows: 0, columns: 0, hasFocusedWindow: false))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(parseBarStatus("not json"))
        XCTAssertNil(parseBarStatus(#"{"workspace":"two"}"#))
        XCTAssertNil(parseBarStatus("{}"))
    }

    func testTitle() {
        XCTAssertEqual(barTitle(nil), "Gio")
        XCTAssertEqual(
            barTitle(BarSessionState(workspace: 2, windows: 5, columns: 3)),
            "2 · 5"
        )
    }

    func testParsesTheWorkspaceStacks() throws {
        let json = #"""
        {"workspace":2,"columns":1,"windows":1,"stacks":[{"display":7,"focused":true,"active":2,
        "workspaces":[{"index":1,"windows":2,"columns":1,"active":false},
        {"index":2,"windows":1,"columns":1,"active":true},
        {"index":3,"windows":0,"columns":0,"active":false}]}]}
        """#
        let state = try XCTUnwrap(parseBarStatus(json))
        XCTAssertEqual(state.stacks.count, 1)
        XCTAssertEqual(state.stacks[0].display, 7)
        XCTAssertTrue(state.stacks[0].focused)
        XCTAssertEqual(state.stacks[0].workspaces.map(\.index), [1, 2, 3])
        XCTAssertEqual(state.stacks[0].workspaces.map(\.windows), [2, 1, 0])
        XCTAssertEqual(state.stacks[0].workspaces.map(\.isActive), [false, true, false])
    }

    func testStatusWithoutStacksStillParses() throws {
        let state = try XCTUnwrap(parseBarStatus(#"{"columns":0,"workspace":1}"#))
        XCTAssertTrue(state.stacks.isEmpty)
    }

    // MARK: - PA-15a: straight from the session

    private func id(_ n: UInt64) -> WindowID {
        WindowID(pid: 7, elementID: n)
    }

    /// Two displays, a named dwindle workspace with an icon and color, a
    /// focused window in a filled workspace and an empty one behind it.
    private func fixtureSession() -> CommandSession {
        var config = defaultGioConfig()
        config.workspaces = [
            WorkspaceDefinition(name: "Code", icon: "hammer", color: "#ff0000", layout: .dwindle),
        ]
        var session = CommandSession(config: config)
        session.manager.syncDisplays([DisplayID(1), DisplayID(2)], main: DisplayID(1))
        var seed = session.manager.currentWorkspace()
        seed.columns = [Column(id: ColumnID(1), width: 300, windows: [id(1), id(2)])]
        session.manager.update(seed)
        XCTAssertTrue(session.manager.switchTo(2))
        var second = session.manager.currentWorkspace()
        second.columns = [
            Column(id: ColumnID(1), width: 300, windows: [id(3)]),
            Column(id: ColumnID(2), width: 300, windows: [id(4)]),
        ]
        second.focusedWindow = id(4)
        session.manager.update(second)
        return session
    }

    func testSessionStateMatchesTheStatusJSON() throws {
        let sessions = [CommandSession(), fixtureSession()]
        for session in sessions {
            let parsed = try XCTUnwrap(parseBarStatus(queryStatus(session: session)))
            XCTAssertEqual(barSessionState(session: session), parsed)
        }
        let filled = barSessionState(session: fixtureSession())
        XCTAssertEqual(filled.workspace, 2)
        XCTAssertEqual(filled.columns, 2)
        XCTAssertTrue(filled.hasFocusedWindow)
        XCTAssertEqual(filled.stacks.count, 2)
    }

    func testFocusMovingBetweenWindowsIsNotABarChange() {
        var session = fixtureSession()
        var gate = BarStateGate()
        XCTAssertTrue(gate.accept(barSessionState(session: session)))
        var workspace = session.manager.currentWorkspace()
        workspace.focusedWindow = id(3)
        workspace.focusedColumn = 0
        session.manager.update(workspace)
        XCTAssertFalse(gate.accept(barSessionState(session: session)), "same counts, focus still present")
        workspace.focusedWindow = nil
        session.manager.update(workspace)
        XCTAssertTrue(gate.accept(barSessionState(session: session)), "losing focus changes the menu")
    }
}
