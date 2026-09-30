import XCTest
@testable import GioCore

/// FI-09: planning the `gio` command install from a built GioCLI.
final class CLIInstallTests: XCTestCase {
    private let root = "/Users/me/Git/gio "
    private let home = "/Users/me"

    func testSourceRootIsThreeLevelsAboveASourceFile() {
        XCTAssertEqual(
            gioSourceRoot(fromSourceFile: "/Users/me/Git/gio /Sources/GioUI/DiagnosticsView.swift"),
            "/Users/me/Git/gio "
        )
        XCTAssertNil(gioSourceRoot(fromSourceFile: "DiagnosticsView.swift"))
    }

    func testPrefersReleaseThenDebugBinary() {
        let both: Set = ["\(root)/.build/release/GioCLI", "\(root)/.build/debug/GioCLI"]
        let plan = planGioCommandInstall(sourceRoot: root, home: home, fileExists: both.contains)
        XCTAssertEqual(plan.binary, "\(root)/.build/release/GioCLI")
        let debugOnly = planGioCommandInstall(sourceRoot: root, home: home) { $0 == "\(root)/.build/debug/GioCLI" }
        XCTAssertEqual(debugOnly.binary, "\(root)/.build/debug/GioCLI")
    }

    func testLinkGoesToLocalBin() {
        let plan = planGioCommandInstall(sourceRoot: root, home: home) { _ in false }
        XCTAssertEqual(plan.linkPath, "/Users/me/.local/bin/gio")
        XCTAssertNil(plan.binary)
    }

    func testShellCommandQuotesTheTrailingSpaceRoot() {
        let plan = planGioCommandInstall(sourceRoot: root, home: home) { _ in false }
        XCTAssertEqual(
            plan.shellCommand,
            "cd '/Users/me/Git/gio ' && swift build --product GioCLI && mkdir -p ~/.local/bin"
                + " && ln -sf '/Users/me/Git/gio /.build/debug/GioCLI' ~/.local/bin/gio"
        )
    }

    func testShellCommandLinksAnExistingBinaryWithoutBuilding() {
        let plan = planGioCommandInstall(sourceRoot: root, home: home) { $0 == "\(root)/.build/release/GioCLI" }
        XCTAssertEqual(
            plan.shellCommand,
            "mkdir -p ~/.local/bin && ln -sf '/Users/me/Git/gio /.build/release/GioCLI' ~/.local/bin/gio"
        )
    }

    func testNoSourceRootFallsBackToAPlaceholder() {
        let plan = planGioCommandInstall(sourceRoot: nil, home: home) { _ in true }
        XCTAssertNil(plan.binary)
        XCTAssertTrue(plan.shellCommand.hasPrefix("cd <path-to-gio-repo> && swift build --product GioCLI"))
    }

    func testPathHint() {
        XCTAssertFalse(localBinOnPath("/usr/bin:/bin", home: home))
        XCTAssertTrue(localBinOnPath("/usr/bin:/Users/me/.local/bin", home: home))
        XCTAssertTrue(localBinOnPath("/usr/bin:/Users/me/.local/bin/", home: home))
    }
}
