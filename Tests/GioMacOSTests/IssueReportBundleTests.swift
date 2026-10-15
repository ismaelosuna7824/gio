import Foundation
import GioCore
import XCTest
@testable import GioMacOS

/// DA-08: the report bundle lands as one zip in the given directory (never
/// the real Downloads here) with the planned files, and no folder is left.
final class IssueReportBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gio-report-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWritesTheZipWithThePlannedFilesAndRemovesTheFolder() throws {
        let logs = root.appendingPathComponent("logs")
        let destination = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("gio.log")
        try "[2026-10-15T08:00:00] [WARN] x\n".write(to: log, atomically: true, encoding: .utf8)
        let input = IssueReportInput(
            title: "", description: "Windows jump", includeConfig: false,
            system: IssueReportSystem(
                version: "1.0.0", macOS: "15", architecture: "arm64", displays: [],
                accessibilityTrusted: true, healthLines: []
            ),
            logPath: log.path, configPath: logs.appendingPathComponent("config.toml").path,
            logText: "", date: Date(timeIntervalSince1970: 0)
        )
        let plan = makeIssueReportPlan(input, fileExists: { FileManager.default.fileExists(atPath: $0) })

        let zip = try writeIssueReportBundle(plan, in: destination)

        XCTAssertEqual(zip.lastPathComponent, plan.zipName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [plan.zipName])
        let unpacked = root.appendingPathComponent("unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let folder = unpacked.appendingPathComponent(plan.folderName)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["description.txt", "gio.log", "system.txt"]
        )
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("gio.log"), encoding: .utf8),
            "[2026-10-15T08:00:00] [WARN] x\n"
        )
    }

    /// Live smoke (real log): `ditto -c -k` stored a `._name` AppleDouble
    /// entry (extended attributes) next to every file; `unzip` on the
    /// receiving side shows them as extra files.
    func testTheZipHoldsOnlyThePlannedFilesWithoutMetadataEntries() throws {
        let logs = root.appendingPathComponent("logs")
        let destination = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("gio.log")
        try "x\n".write(to: log, atomically: true, encoding: .utf8)
        let input = IssueReportInput(
            title: "", description: "x", includeConfig: false,
            system: IssueReportSystem(
                version: "1", macOS: "15", architecture: "arm64", displays: [], accessibilityTrusted: true, healthLines: []
            ),
            logPath: log.path, configPath: logs.appendingPathComponent("config.toml").path,
            logText: "", date: Date(timeIntervalSince1970: 0)
        )
        let plan = makeIssueReportPlan(input, fileExists: { FileManager.default.fileExists(atPath: $0) })
        let zip = try writeIssueReportBundle(plan, in: destination)

        let list = Process()
        let pipe = Pipe()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        list.standardOutput = pipe
        try list.run()
        list.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").filter { !$0.hasSuffix("/") }.map { String($0.split(separator: "/").last ?? "") }
        XCTAssertEqual(entries.sorted(), ["description.txt", "gio.log", "system.txt"])
    }

    func testAMissingDestinationFailsWithoutLeavingAFolder() {
        let input = IssueReportInput(
            title: "", description: "x", includeConfig: false,
            system: IssueReportSystem(
                version: "1", macOS: "15", architecture: "arm64", displays: [], accessibilityTrusted: false, healthLines: []
            ),
            logPath: "/nonexistent/gio.log", configPath: "/nonexistent/config.toml", logText: "", date: Date()
        )
        let plan = makeIssueReportPlan(input, fileExists: { _ in false })
        XCTAssertThrowsError(try writeIssueReportBundle(plan, in: root.appendingPathComponent("missing")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }
}
