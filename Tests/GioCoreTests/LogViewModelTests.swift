import XCTest
@testable import GioCore

/// DA-05: pure pieces behind the Logs and Diagnostics sections.
final class LogViewModelTests: XCTestCase {
    private func entry(_ level: LogLevel, _ message: String) -> LogEntry {
        LogEntry(timestamp: "2026-01-01T00:00:00Z", level: level, message: message)
    }

    func testLevelThresholdKeepsThatLevelAndAbove() {
        let all = [entry(.error, "e"), entry(.warn, "w"), entry(.info, "i"), entry(.debug, "d"), entry(.trace, "t")]
        XCTAssertEqual(LogFilter(minLevel: .warn).apply(to: all).map(\.message), ["e", "w"])
        XCTAssertEqual(LogFilter(minLevel: .trace).apply(to: all).count, 5)
    }

    func testSearchIsCaseInsensitiveOnMessageAndLevelName() {
        let all = [entry(.info, "Reflow took 12ms"), entry(.warn, "ax write failed"), entry(.info, "other")]
        var filter = LogFilter(minLevel: .trace)
        filter.search = "REFLOW"
        XCTAssertEqual(filter.apply(to: all).map(\.message), ["Reflow took 12ms"])
        filter.search = "warn"
        XCTAssertEqual(filter.apply(to: all).map(\.message), ["ax write failed"])
    }

    func testBlankSearchDoesNotFilter() {
        let all = [entry(.info, "a"), entry(.info, "b")]
        var filter = LogFilter(minLevel: .trace)
        filter.search = "   "
        XCTAssertEqual(filter.apply(to: all).count, 2)
    }

    func testParseSkipsLinesThisStoreDidNotWrite() {
        let good = entry(.warn, "x=1").line()
        let parsed = parseLogEntries("noise\n\(good)\n\n[bad] [NOPE] y\n")
        XCTAssertEqual(parsed, [entry(.warn, "x=1")])
    }

    func testDefaultFilterHidesDebugNoise() {
        XCTAssertEqual(LogFilter().minLevel, .info)
    }
}

final class LogTailReaderTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-tail-\(UUID().uuidString).log").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func line(_ n: Int) -> String {
        LogEntry(timestamp: "2026-01-01T00:00:00Z", level: .info, message: "m\(n)").line() + "\n"
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(readLogEntries(path: path), [])
        XCTAssertEqual(logFileSize(path: path), 0)
    }

    func testReadsEverythingWhenSmall() throws {
        try (line(1) + line(2)).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(readLogEntries(path: path).map(\.message), ["m1", "m2"])
    }

    func testFromOffsetSkipsWhatWasCleared() throws {
        try line(1).write(toFile: path, atomically: true, encoding: .utf8)
        let mark = logFileSize(path: path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        XCTAssertEqual(readLogEntries(path: path, fromOffset: mark).map(\.message), ["m2"])
    }

    func testMaxBytesKeepsTheTailAndDropsAPartialFirstLine() throws {
        let body = (1...50).map(line).joined()
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        let lineLength = UInt64(line(10).utf8.count)
        let entries = readLogEntries(path: path, maxBytes: lineLength * 3 + 5)
        XCTAssertEqual(entries.map(\.message), ["m48", "m49", "m50"])
    }
}

final class DiagnosticsTests: XCTestCase {
    private func facts(
        granted: Bool = true, exists: Bool = true, messages: [String] = [], displays: Int = 2
    ) -> SessionFacts {
        SessionFacts(
            configPath: "/tmp/config.toml", configExists: exists, configMessages: messages,
            accessibilityGranted: granted, currentWorkspace: 1,
            displays: (0..<displays).map { DisplayFact(id: UInt32($0 + 1), workspace: $0 + 1) },
            windows: [], screenRecordingGranted: true
        )
    }

    private func rows(_ facts: SessionFacts, socket: Bool = true) -> [String: DiagnosticRow] {
        Dictionary(uniqueKeysWithValues: makeDiagnostics(
            facts: facts, version: "0.1.0", build: "42", socketPath: "/tmp/gio.sock",
            socketExists: socket, logPath: "/tmp/gio.log"
        ).map { ($0.title, $0) })
    }

    func testHealthySessionIsAllOk() {
        let all = rows(facts())
        XCTAssertTrue(all.values.allSatisfy { $0.status == .ok }, "\(all)")
        XCTAssertEqual(all["Version"]?.value, "0.1.0 (build 42)")
        XCTAssertEqual(all["Displays"]?.value, "2")
        XCTAssertEqual(all["IPC socket"]?.value, "/tmp/gio.sock")
    }

    func testMissingAccessibilityFails() {
        XCTAssertEqual(rows(facts(granted: false))["Accessibility"]?.status, .failure)
    }

    func testConfigMessagesWarnAndMissingFileIsDefaults() {
        let warned = rows(facts(messages: ["line 3: bad"]))["Config"]
        XCTAssertEqual(warned?.status, .warning)
        XCTAssertTrue(warned?.value.contains("1 message") ?? false)
        let missing = rows(facts(exists: false))["Config"]
        XCTAssertEqual(missing?.status, .ok)
        XCTAssertTrue(missing?.value.contains("defaults") ?? false)
    }

    func testMissingSocketFails() {
        XCTAssertEqual(rows(facts(), socket: false)["IPC socket"]?.status, .failure)
    }

    func testBuildIsOptional() {
        let list = makeDiagnostics(
            facts: facts(), version: "0.1.0", build: nil, socketPath: "s", socketExists: true, logPath: "l"
        )
        XCTAssertEqual(list.first { $0.title == "Version" }?.value, "0.1.0")
    }
}
