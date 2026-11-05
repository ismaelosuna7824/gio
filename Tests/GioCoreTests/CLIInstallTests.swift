import XCTest
@testable import GioCore

/// SB-01: the app binary is the `gio` CLI. Install Command Line Tool links
/// `~/.local/bin/gio` to the running bundle's executable; a launch named
/// `gio` runs the client instead of the app.
final class CLIInstallTests: XCTestCase {
    private let home = "/Users/me"
    private let link = "/Users/me/.local/bin/gio"
    private let executable = "/Applications/Gio.app/Contents/MacOS/Gio"

    /// In-memory file system: paths to symlink destinations or plain files.
    private final class FakeFileSystem: CLIToolFileSystem {
        var links: [String: String] = [:]
        var files: Set<String> = []
        var directories: Set<String> = []
        var failCreate = false

        func linkState(at path: String) -> CLIToolLinkState {
            if let destination = links[path] {
                return .symlink(to: destination)
            }
            return files.contains(path) || directories.contains(path) ? .otherFile : .missing
        }

        func createDirectory(_ path: String) throws {
            directories.insert(path)
        }

        func removeItem(_ path: String) throws {
            links.removeValue(forKey: path)
        }

        func createSymlink(at path: String, to destination: String) throws {
            if failCreate {
                throw CocoaError(.fileWriteNoPermission)
            }
            links[path] = destination
        }
    }

    func testTargetIsTheRunningBundlesExecutable() {
        XCTAssertEqual(
            cliToolTarget(bundlePath: "/Applications/Gio.app", executablePath: executable), executable
        )
        XCTAssertNil(
            cliToolTarget(bundlePath: "/Users/me/gio/.build/debug", executablePath: "/Users/me/gio/.build/debug/GioDesktop"),
            "swift run has no bundle to link"
        )
        XCTAssertNil(cliToolTarget(bundlePath: "/Applications/Gio.app", executablePath: nil))
    }

    func testPlanCreatesTheLinkWhenNothingIsThere() {
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .missing),
            .create(link: link, target: executable)
        )
    }

    func testPlanReplacesAnOlderGioLink() {
        let dev = "/Users/me/gio /.build/GioAutoTeam/Build/Products/Debug/Gio.app/Contents/MacOS/Gio"
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .symlink(to: dev)),
            .replace(link: link, previous: dev, target: executable)
        )
        let built = "/Users/me/gio/.build/debug/GioCLI"
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .symlink(to: built)),
            .replace(link: link, previous: built, target: executable), "the FI-09 link to a built GioCLI"
        )
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .symlink(to: executable)),
            .alreadyInstalled(link: link)
        )
    }

    func testPlanRefusesForeignFilesAndLinks() {
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .otherFile),
            .refuse(reason: "~/.local/bin/gio exists and is not a link to Gio. Remove it, then try again.")
        )
        XCTAssertEqual(
            planCLIToolInstall(target: executable, home: home, existing: .symlink(to: "/opt/homebrew/bin/gio")),
            .refuse(reason: "~/.local/bin/gio links to /opt/homebrew/bin/gio, not to Gio. Remove it, then try again.")
        )
        XCTAssertEqual(
            planCLIToolInstall(target: nil, home: home, existing: .missing),
            .refuse(reason: "Open Gio.app to install the command line tool (this copy is not an app bundle).")
        )
    }

    func testInstallCreatesTheDirectoryAndTheLink() {
        let files = FakeFileSystem()
        XCTAssertEqual(
            installCLITool(target: executable, home: home, fileSystem: files),
            .installed(link: link, target: executable, replaced: nil)
        )
        XCTAssertEqual(files.links[link], executable)
        XCTAssertTrue(files.directories.contains("/Users/me/.local/bin"))
    }

    func testInstallReplacesAnOldLinkAndNeverAFile() {
        let files = FakeFileSystem()
        files.links[link] = "/Old/Gio.app/Contents/MacOS/Gio"
        XCTAssertEqual(
            installCLITool(target: executable, home: home, fileSystem: files),
            .installed(link: link, target: executable, replaced: "/Old/Gio.app/Contents/MacOS/Gio")
        )
        XCTAssertEqual(files.links[link], executable)
        let occupied = FakeFileSystem()
        occupied.files.insert(link)
        guard case .refused = installCLITool(target: executable, home: home, fileSystem: occupied) else {
            return XCTFail("a regular file is never overwritten")
        }
        XCTAssertTrue(occupied.links.isEmpty)
    }

    func testInstallReportsAFailedWrite() {
        let files = FakeFileSystem()
        files.failCreate = true
        guard case .failed = installCLITool(target: executable, home: home, fileSystem: files) else {
            return XCTFail("expected a failure")
        }
    }

    func testLiveFileSystemRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gio-cli-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = LiveCLIToolFileSystem()
        let outcome = installCLITool(target: "/Applications/Gio.app/Contents/MacOS/Gio", home: root, fileSystem: files)
        XCTAssertEqual(
            outcome, .installed(link: "\(root)/.local/bin/gio", target: "/Applications/Gio.app/Contents/MacOS/Gio", replaced: nil)
        )
        XCTAssertEqual(files.linkState(at: "\(root)/.local/bin/gio"), .symlink(to: "/Applications/Gio.app/Contents/MacOS/Gio"))
        try "x".write(toFile: "\(root)/plain", atomically: true, encoding: .utf8)
        XCTAssertEqual(files.linkState(at: "\(root)/plain"), .otherFile)
        XCTAssertEqual(files.linkState(at: "\(root)/none"), .missing)
    }

    func testPathHint() {
        XCTAssertFalse(localBinOnPath("/usr/bin:/bin", home: home))
        XCTAssertTrue(localBinOnPath("/usr/bin:/Users/me/.local/bin", home: home))
        XCTAssertTrue(localBinOnPath("/usr/bin:/Users/me/.local/bin/", home: home))
    }

    // MARK: - The app binary as the CLI

    func testALaunchNamedGioIsTheCLI() {
        XCTAssertTrue(isGioCLIInvocation(["gio", "status"]))
        XCTAssertTrue(isGioCLIInvocation(["/Users/me/.local/bin/gio"]))
        XCTAssertFalse(isGioCLIInvocation(["/Applications/Gio.app/Contents/MacOS/Gio"]), "case-sensitive: the app itself")
        XCTAssertFalse(isGioCLIInvocation(["/Applications/Gio.app/Contents/MacOS/Gio", "--guardian", "12"]))
        XCTAssertFalse(isGioCLIInvocation([]))
    }

    func testClientPrintsUsageWithoutArguments() {
        var out: [String] = []
        var err: [String] = []
        let code = runGioCLI(arguments: [], socketPath: "/nonexistent.sock", output: { out.append($0) }, error: { err.append($0) })
        XCTAssertEqual(code, 2)
        XCTAssertEqual(out, [cliUsage()])
        XCTAssertEqual(err, [])
    }

    func testClientWithoutASessionFails() {
        var err: [String] = []
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gio-cli-\(UUID().uuidString).sock").path
        let code = runGioCLI(arguments: ["status"], socketPath: path, output: { _ in }, error: { err.append($0) })
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.first?.hasPrefix("no running Gio session") == true, "\(err)")
    }

    func testClientPrintsTheSessionsAnswer() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gio-cli-\(UUID().uuidString).sock").path
        let server = IPCServer(socketPath: path) { argv in
            argv == ["fail"]
                ? IPCResponse(ok: false, error: "unknownCommand(\"fail\")")
                : IPCResponse(ok: true, output: argv.joined(separator: " "))
        }
        try server.start()
        defer { server.stop() }
        var out: [String] = []
        XCTAssertEqual(runGioCLI(arguments: ["list-workspaces", "--json"], socketPath: path, output: { out.append($0) }, error: { _ in }), 0)
        XCTAssertEqual(out, ["list-workspaces --json"])
        var err: [String] = []
        XCTAssertEqual(runGioCLI(arguments: ["fail"], socketPath: path, output: { _ in }, error: { err.append($0) }), 1)
        XCTAssertEqual(err, ["unknownCommand(\"fail\")"])
    }
}
