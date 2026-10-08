import XCTest
@testable import GioCore

/// HD-08: every test bundle logs to a throwaway file. The global `GioLog`
/// resolves its default path once per process; under XCTest that default is
/// a per-process temp file, so a suite that never sets `logFilePath` cannot
/// append fixture lines to the user's `~/.config/gio/gio.log`. The real file
/// is never opened or read here: assertions are on resolved paths only.
final class TestLogIsolationTests: XCTestCase {
    private let realPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/gio.log"
    private var savedPath = ""

    override func setUp() {
        super.setUp()
        savedPath = GioLog.logFilePath
        GioLog.clearForTests()
    }

    override func tearDown() {
        GioLog.clearForTests()
        GioLog.logFilePath = savedPath
        super.tearDown()
    }

    func testOutsideXCTestTheDefaultIsTheRealLog() {
        XCTAssertEqual(
            GioLog.resolveDefaultLogFilePath(home: "/Users/u", temporaryDirectory: "/tmp/x/", underXCTest: false, pid: 42),
            "/Users/u/.config/gio/gio.log"
        )
    }

    func testUnderXCTestTheDefaultIsAPerProcessTempFile() {
        XCTAssertEqual(
            GioLog.resolveDefaultLogFilePath(home: "/Users/u", temporaryDirectory: "/tmp/x/", underXCTest: true, pid: 42),
            "/tmp/x/gio-xctest-42.log"
        )
    }

    func testThisProcessIsDetectedAsXCTest() {
        XCTAssertTrue(GioLog.isRunningUnderXCTest)
    }

    func testProcessDefaultIsNotTheRealLog() {
        XCTAssertNotEqual(GioLog.defaultLogFilePath, realPath)
        XCTAssertTrue(GioLog.defaultLogFilePath.hasPrefix(NSTemporaryDirectory()))
    }

    func testGlobalLogWithTheDefaultPathNeverOpensTheRealFile() {
        GioLog.logFilePath = GioLog.defaultLogFilePath
        GioLog.record(.warn, "reconcile failure id=30:1 app=pid30 kind=timeout")
        GioLog.flush()
        XCTAssertEqual(GioLog.activeSinkPath, GioLog.defaultLogFilePath)
        XCTAssertNotEqual(GioLog.activeSinkPath, realPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: GioLog.defaultLogFilePath))
    }
}
