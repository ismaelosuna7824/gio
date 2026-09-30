import XCTest
@testable import GioCore

/// PA-01: level gate, persistent batched sink, rotation, parse compatibility.
final class LogSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GioLog.clearForTests()
        GioLog.logFilePath = directory.appendingPathComponent("gio.log").path
    }

    override func tearDown() {
        GioLog.clearForTests()
        GioLog.minimumLevel = .info
        try? FileManager.default.removeItem(at: directory)
    }

    func testBelowMinimumLevelNeverEvaluatesMessage() {
        GioLog.minimumLevel = .info
        var evaluations = 0
        GioLog.record(.debug, { evaluations += 1; return "expensive" }())
        XCTAssertEqual(evaluations, 0)
        GioLog.record(.info, { evaluations += 1; return "kept" }())
        XCTAssertEqual(evaluations, 1)
        XCTAssertEqual(GioLog.entries().map(\.message), ["kept"])
    }

    func testDefaultMinimumLevelIsInfo() {
        // clearForTests opens the gate for other suites; the production default is info.
        XCTAssertEqual(LoggingSectionConfig().level, .info)
        XCTAssertEqual(defaultGioConfig().logging.level, .info)
    }

    func testFlushWritesQueuedLinesAndTheyParse() throws {
        GioLog.record(.info, "alpha=1")
        GioLog.record(.error, "beta=2")
        GioLog.flush()
        let text = try String(contentsOfFile: GioLog.logFilePath, encoding: .utf8)
        let entries = parseLogEntries(text)
        XCTAssertEqual(entries.map(\.message), ["alpha=1", "beta=2"])
        XCTAssertEqual(entries.map(\.level), [.info, .error])
        XCTAssertTrue(entries[0].timestamp.hasSuffix("Z"))
    }

    func testSinkBatchesUntilFlushOrFull() throws {
        let path = directory.appendingPathComponent("batch.log").path
        let sink = LogFileSink(path: path, maxBatch: 3, flushDelay: 60)
        sink.append("[t] [INFO] one")
        sink.append("[t] [INFO] two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nothing written before batch is full")
        sink.flush()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[t] [INFO] one\n[t] [INFO] two\n")
        for name in ["a", "b", "c"] {
            sink.append("[t] [INFO] \(name)")
        }
        sink.flush() // waits for the queued full-batch drain
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("a\n[t] [INFO] b\n[t] [INFO] c\n"))
    }

    func testTimerFlushWritesWithoutExplicitFlush() throws {
        let path = directory.appendingPathComponent("timer.log").path
        let sink = LogFileSink(path: path, maxBatch: 100, flushDelay: 0.05)
        sink.append("[t] [INFO] later")
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        sink.flush()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[t] [INFO] later\n")
    }

    func testRotationKeepsOneBackup() throws {
        let path = directory.appendingPathComponent("rot.log").path
        let sink = LogFileSink(path: path, maxBytes: 200, maxBatch: 1, flushDelay: 60)
        let line = "[t] [INFO] " + String(repeating: "x", count: 88) // 100 bytes with newline
        for _ in 0..<5 {
            sink.append(line)
            sink.flush()
        }
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: path + ".1"))
        XCTAssertFalse(manager.fileExists(atPath: path + ".2"))
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let backup = try String(contentsOfFile: path + ".1", encoding: .utf8)
        XCTAssertLessThanOrEqual(current.utf8.count, 200)
        XCTAssertLessThanOrEqual(backup.utf8.count, 200)
        XCTAssertEqual(current.split(separator: "\n").count + backup.split(separator: "\n").count, 3)
    }

    func testSinkReopensWhenFileIsRemoved() throws {
        let path = directory.appendingPathComponent("gone.log").path
        let sink = LogFileSink(path: path, maxBatch: 1, flushDelay: 60)
        sink.append("[t] [INFO] first")
        sink.flush()
        try FileManager.default.removeItem(atPath: path)
        sink.append("[t] [INFO] second")
        sink.flush()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[t] [INFO] second\n")
    }

    /// Two sinks on one path stand in for Gio and its guardian (two
    /// processes, two descriptors): every line must survive whole.
    func testTwoWritersOnOnePathNeverSpliceOrLoseLines() throws {
        let path = directory.appendingPathComponent("shared.log").path
        let main = LogFileSink(path: path, maxBatch: 7, flushDelay: 60)
        let guardian = LogFileSink(path: path, maxBatch: 1, flushDelay: 60, rotates: false)
        let count = 400
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            let sink = writer == 0 ? main : guardian
            for index in 0..<count {
                sink.append("[2026-09-30T02:20:07Z] [INFO] writer=\(writer) line=\(index) " + String(repeating: "x", count: 60))
            }
            sink.flush()
        }
        main.flush()
        guardian.flush()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2 * count)
        for line in lines {
            XCTAssertNotNil(LogEntry.parse(line), line)
            XCTAssertTrue(line.hasSuffix(String(repeating: "x", count: 60)), line)
        }
        for writer in 0..<2 {
            XCTAssertEqual(lines.filter { $0.contains("writer=\(writer) ") }.count, count)
        }
    }

    /// Only the main process rotates; the guardian's sink follows the rename
    /// to the fresh file instead of writing into the backup.
    func testNonRotatingWriterFollowsTheRotationOfTheOther() throws {
        let path = directory.appendingPathComponent("follow.log").path
        let main = LogFileSink(path: path, maxBytes: 150, maxBatch: 1, flushDelay: 60)
        let guardian = LogFileSink(path: path, maxBytes: 10, maxBatch: 1, flushDelay: 60, rotates: false)
        let line = "[t] [INFO] " + String(repeating: "m", count: 88)
        guardian.append("[t] [INFO] guardian-before")
        guardian.flush()
        main.append(line)
        main.flush()
        main.append(line) // over maxBytes: main renames to .1 and starts fresh
        main.flush()
        guardian.append("[t] [INFO] guardian-after")
        guardian.flush()
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let backup = try String(contentsOfFile: path + ".1", encoding: .utf8)
        XCTAssertTrue(current.contains("guardian-after"), current)
        XCTAssertFalse(backup.contains("guardian-after"), backup)
        XCTAssertTrue(backup.contains("guardian-before"), backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".2"))
    }

    func testNonRotatingWriterNeverRenames() throws {
        let path = directory.appendingPathComponent("norotate.log").path
        let sink = LogFileSink(path: path, maxBytes: 10, maxBatch: 1, flushDelay: 60, rotates: false)
        for index in 0..<3 {
            sink.append("[t] [INFO] line \(index)")
            sink.flush()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count, 3)
    }

    func testConfigLoggingLevel() throws {
        let (config, warnings) = try parseGioConfig("[logging]\nlevel = \"Debug\"\n").get()
        XCTAssertEqual(config.logging.level, .debug)
        XCTAssertTrue(warnings.isEmpty)
        guard case .failure(let errors) = parseGioConfig("[logging]\nlevel = \"loud\"\n") else {
            return XCTFail("invalid level must be an error")
        }
        XCTAssertTrue(errors.messages.joined().contains("logging.level"))
        let (extra, extraWarnings) = try parseGioConfig("[logging]\nverbosity = 3\n").get()
        XCTAssertEqual(extra.logging.level, .info)
        XCTAssertEqual(extraWarnings.count, 1)
        let template = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertEqual(template.0.logging.level, .info)
    }
}
