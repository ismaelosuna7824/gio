import XCTest
@testable import GioCore

/// PA-02: incremental tail of the log file (append, partial line, rotation,
/// truncation, clear, row cap).
final class LogTailTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("gio.log").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ message: String, _ level: String = "INFO") -> String {
        "[2026-01-01T00:00:00Z] [\(level)] \(message)\n"
    }

    private func append(_ text: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    func testMissingFileIsEmptyAndUnchanged() {
        var tail = LogTail(path: path)
        XCTAssertFalse(tail.poll())
        XCTAssertEqual(tail.entries, [])
    }

    func testReadsOnlyAppendedLinesAfterFirstPoll() throws {
        try append(line("one") + line("two"))
        var tail = LogTail(path: path)
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["one", "two"])
        XCTAssertFalse(tail.poll(), "nothing new: no change")
        try append(line("three"))
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["one", "two", "three"])
    }

    func testPartialTrailingLineWaitsForItsNewline() throws {
        var tail = LogTail(path: path)
        try append(line("whole") + "[2026-01-01T00:00:00Z] [WARN] half")
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["whole"])
        try append(" done\n")
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["whole", "half done"])
    }

    func testRotationRestartsFromTheNewFile() throws {
        try append(line("old-1") + line("old-2"))
        var tail = LogTail(path: path)
        _ = tail.poll()
        try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        try append(line("new-1"))
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["old-1", "old-2", "new-1"])
    }

    func testTruncationRestartsFromTheStart() throws {
        try append(line("a") + line("b") + line("c"))
        var tail = LogTail(path: path)
        _ = tail.poll()
        try line("fresh").write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.last?.message, "fresh")
    }

    func testClearHidesExistingLinesOnly() throws {
        try append(line("before"))
        var tail = LogTail(path: path)
        _ = tail.poll()
        tail.clear()
        XCTAssertEqual(tail.entries, [])
        XCTAssertFalse(tail.poll())
        try append(line("after"))
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.entries.map(\.message), ["after"])
    }

    func testEntryCapKeepsTheNewest() throws {
        var tail = LogTail(path: path, maxEntries: 3)
        try append((0..<10).map { line("m\($0)") }.joined())
        _ = tail.poll()
        XCTAssertEqual(tail.entries.map(\.message), ["m7", "m8", "m9"])
    }

    func testFirstReadOfHugeFileIsBoundedAndDropsPartialLine() throws {
        let big = (0..<200).map { line("row\($0) " + String(repeating: "x", count: 100)) }.joined()
        try append(big)
        var tail = LogTail(path: path, maxEntries: 1000, initialBytes: 1024)
        _ = tail.poll()
        XCTAssertLessThan(tail.entries.count, 12)
        XCTAssertTrue(tail.entries.allSatisfy { $0.message.hasPrefix("row") })
        XCTAssertEqual(tail.entries.last?.message.hasPrefix("row199"), true)
    }
}
