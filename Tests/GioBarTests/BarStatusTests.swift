import XCTest
@testable import GioBar

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
}
