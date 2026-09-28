import XCTest
@testable import GioPOC

final class CLICommandTests: XCTestCase {
    func testParseListWindows() throws {
        XCTAssertEqual(try parseCLICommand(["list-windows"]).get(), .listWindows)
    }

    func testParseFocus() throws {
        XCTAssertEqual(try parseCLICommand(["focus", "2"]).get(), .focus(index: 2))
        XCTAssertEqual(
            parseCLICommand(["focus"]).mapError { $0 }.failure,
            .missingArgument(name: "index", command: "focus")
        )
    }

    func testParseMove() throws {
        XCTAssertEqual(
            try parseCLICommand(["move", "1", "100", "200"]).get(),
            .move(index: 1, x: 100, y: 200)
        )
        XCTAssertEqual(
            parseCLICommand(["move", "1", "x", "200"]).mapError { $0 }.failure,
            .invalidNumber("x")
        )
    }

    func testParseResize() throws {
        XCTAssertEqual(
            try parseCLICommand(["resize", "0", "800", "600"]).get(),
            .resize(index: 0, width: 800, height: 600)
        )
        XCTAssertEqual(
            parseCLICommand(["resize", "0", "0", "600"]).mapError { $0 }.failure,
            .nonPositiveSize
        )
    }

    func testParseEventsHelpAndUnknown() throws {
        XCTAssertEqual(try parseCLICommand(["events"]).get(), .events)
        XCTAssertEqual(try parseCLICommand(["tile"]).get(), .tile)
        XCTAssertEqual(try parseCLICommand(["help"]).get(), .help)
        XCTAssertEqual(parseCLICommand([]).mapError { $0 }.failure, .noArguments)
        XCTAssertEqual(
            parseCLICommand(["frobnicate"]).mapError { $0 }.failure,
            .unknownCommand("frobnicate")
        )
    }

    func testUsageMentionsAllVerbs() {
        let usage = cliUsage()
        for verb in ["list-windows", "focus", "move", "resize", "tile", "events"] {
            XCTAssertTrue(usage.contains(verb), "usage missing \(verb)")
        }
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
