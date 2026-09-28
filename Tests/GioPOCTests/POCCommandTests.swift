import XCTest
@testable import GioPOC

final class POCCommandTests: XCTestCase {
    func testParseListWindows() throws {
        XCTAssertEqual(try parsePOCCommand(["list-windows"]).get(), .listWindows)
    }

    func testParseFocus() throws {
        XCTAssertEqual(try parsePOCCommand(["focus", "2"]).get(), .focus(index: 2))
        XCTAssertEqual(
            try parsePOCCommand(["focus"]).mapError { $0 }.failure,
            .missingArgument(name: "index", command: "focus")
        )
    }

    func testParseMove() throws {
        XCTAssertEqual(
            try parsePOCCommand(["move", "1", "100", "200"]).get(),
            .move(index: 1, x: 100, y: 200)
        )
        XCTAssertEqual(
            try parsePOCCommand(["move", "1", "x", "200"]).mapError { $0 }.failure,
            .invalidNumber("x")
        )
    }

    func testParseResize() throws {
        XCTAssertEqual(
            try parsePOCCommand(["resize", "0", "800", "600"]).get(),
            .resize(index: 0, width: 800, height: 600)
        )
        XCTAssertEqual(
            try parsePOCCommand(["resize", "0", "0", "600"]).mapError { $0 }.failure,
            .nonPositiveSize
        )
    }

    func testParseEventsHelpAndUnknown() throws {
        XCTAssertEqual(try parsePOCCommand(["events"]).get(), .events)
        XCTAssertEqual(try parsePOCCommand(["help"]).get(), .help)
        XCTAssertEqual(try parsePOCCommand([]).mapError { $0 }.failure, .noArguments)
        XCTAssertEqual(
            try parsePOCCommand(["frobnicate"]).mapError { $0 }.failure,
            .unknownCommand("frobnicate")
        )
    }

    func testUsageMentionsAllVerbs() {
        let usage = pocUsage()
        for verb in ["list-windows", "focus", "move", "resize", "events"] {
            XCTAssertTrue(usage.contains(verb), "usage missing \(verb)")
        }
    }
}

private extension Result where Failure == POCCommandError {
    var failure: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
