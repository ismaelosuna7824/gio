import XCTest
@testable import GioUI

/// Bar state parsing and title rendering. The AppKit shell (status item,
/// menu, timer) is thin and live-only by design.
final class BarStatusTests: XCTestCase {
    func testParseValidStatus() {
        let state = parseBarStatus(
            #"{"columns":3,"focusedWindow":"7:3","workspace":2,"windows":5}"#
        )
        XCTAssertEqual(state, BarSessionState(workspace: 2, windows: 5, columns: 3, focused: "7:3"))
    }

    func testParseToleratesMissingOptionals() {
        let state = parseBarStatus(#"{"columns":0,"workspace":1}"#)
        XCTAssertEqual(state, BarSessionState(workspace: 1, windows: 0, columns: 0, focused: nil))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(parseBarStatus("not json"))
        XCTAssertNil(parseBarStatus(#"{"workspace":"two"}"#))
        XCTAssertNil(parseBarStatus("{}"))
    }

    func testTitle() {
        XCTAssertEqual(barTitle(nil), "Gio")
        XCTAssertEqual(
            barTitle(BarSessionState(workspace: 2, windows: 5, columns: 3, focused: nil)),
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
}
