import XCTest
@testable import GioCore

/// Plan §31: levels, ring behavior, file sink, `logs` verb. Window titles
/// never reach the log — messages carry IDs and counts by construction.
final class GioLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GioLog.clearForTests()
        GioLog.logFilePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-log-test-\(UUID().uuidString).log").path
    }

    func testLevelOrderingAndNames() {
        XCTAssertTrue(LogLevel.trace < .debug)
        XCTAssertTrue(LogLevel.debug < .info)
        XCTAssertTrue(LogLevel.info < .warn)
        XCTAssertTrue(LogLevel.warn < .error)
        XCTAssertEqual(LogLevel(name: "DEBUG"), .debug)
        XCTAssertNil(LogLevel(name: "verbose"))
        XCTAssertEqual(LogLevel.error.name, "error")
    }

    func testLineRoundTrip() {
        let entry = LogEntry(timestamp: "2026-01-01T00:00:00Z", level: .warn, message: "a=b c=1")
        XCTAssertEqual(LogEntry.parse(entry.line()), entry)
        XCTAssertNil(LogEntry.parse("garbage line"))
        XCTAssertNil(LogEntry.parse("[x] [NOPE] y"))
    }

    /// Latency between a key and the motion it starts is tens of
    /// milliseconds: a line carries the time it was recorded to the
    /// millisecond, not its second.
    func testALineIsStampedToTheMillisecond() throws {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for _ in 0..<5 {
            let before = Date()
            GioLog.record(.info, "stamp=1")
            let after = Date()
            let stamp = try XCTUnwrap(GioLog.entries().last?.timestamp)
            XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression), stamp)
            let date = try XCTUnwrap(parser.date(from: stamp), stamp)
            XCTAssertGreaterThanOrEqual(date.timeIntervalSince(before), -0.001, stamp)
            XCTAssertLessThanOrEqual(date.timeIntervalSince(after), 0.001, stamp)
            Thread.sleep(forTimeInterval: 0.003)
        }
    }

    func testRingCapsAndFilters() {
        for index in 0..<600 {
            GioLog.record(index % 2 == 0 ? .debug : .error, "m\(index)")
        }
        XCTAssertEqual(GioLog.entries().count, 500)
        XCTAssertEqual(GioLog.entries(minLevel: .error).count, 250)
        XCTAssertTrue(GioLog.entries(minLevel: .error).allSatisfy { $0.level == .error })
    }

    func testFileSinkAndLevelFilter() {
        GioLog.record(.info, "hello=1")
        GioLog.record(.error, "boom=2")
        let all = GioLog.readFile()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all[0].contains("[INFO] hello=1"))
        let errors = GioLog.readFile(minLevel: .error)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("boom=2"))
    }

    func testReadMissingFileIsEmpty() {
        XCTAssertEqual(GioLog.readFile(path: "/nonexistent/gio-test.log"), [])
    }

    func testLogsVerb() {
        GioLog.record(.info, "a=1")
        var session = CommandSession()
        XCTAssertTrue(dispatch(.logs(nil), session: &session).contains("a=1"))
        XCTAssertTrue(dispatch(.logs(.error), session: &session).contains("no log yet"))
        XCTAssertEqual(try parseCLICommand(["logs"]).get(), .logs(nil))
        XCTAssertEqual(try parseCLICommand(["logs", "--level", "debug"]).get(), .logs(.debug))
        XCTAssertEqual(
            parseCLICommand(["logs", "--level", "verbose"]).mapError { $0 }.failure,
            .invalidLevel("verbose")
        )
        XCTAssertTrue(cliUsage().contains("gio logs"))
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
