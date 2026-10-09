@testable import GioCore
import XCTest

/// UP-05: the detached helper that swaps the bundle after Gio quit, and the
/// `gio update` request/answer text.
final class UpdateInstallScriptTests: XCTestCase {
    func testShellQuoting() {
        XCTAssertEqual(shellQuoted("/Applications/Gio.app"), "'/Applications/Gio.app'")
        XCTAssertEqual(shellQuoted("/Users/me/gio /Gio.app"), "'/Users/me/gio /Gio.app'")
        XCTAssertEqual(shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuoted("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }

    func testStagingAndAsideFoldersAreFreshHiddenTemplatesNextToTheTarget() {
        XCTAssertEqual(updateStagingTemplate(target: "/Applications/Gio.app"), "/Applications/.gio-update-XXXXXX")
        XCTAssertEqual(updateAsideTemplate(target: "/Users/me/My Apps/Gio.app"), "/Users/me/My Apps/.gio-previous-XXXXXX")
    }

    func testStagingFolderIsOnlyRecognisedFromThePrivateTemplate() {
        XCTAssertEqual(
            updateStagingDirectory(ofStagedApp: "/Applications/.gio-update-a1B2c3/Gio.app"), "/Applications/.gio-update-a1B2c3"
        )
        XCTAssertNil(updateStagingDirectory(ofStagedApp: "/Applications/Gio.app"))
        XCTAssertNil(updateStagingDirectory(ofStagedApp: "/Applications/.Gio-0.3.0-update.app"))
        XCTAssertNil(updateStagingDirectory(ofStagedApp: "/Applications/.gio-update-a1B2c3/Other.app"))
        XCTAssertNil(updateStagingDirectory(ofStagedApp: "/Applications/.gio-update-/Gio.app"))
    }

    private let requirement = #"(identifier "dev.gio.windowmanager" and certificate leaf[subject.CN] = "Apple Development: O'Brien (X)") and anchor apple generic"#

    private func plan(relaunch: Bool = true) -> UpdateInstallPlan {
        UpdateInstallPlan(
            target: "/Users/me/My Apps/Gio.app", staged: "/Users/me/My Apps/.gio-update-a1B2c3/Gio.app",
            stagingDirectory: "/Users/me/My Apps/.gio-update-a1B2c3", requirement: requirement, waitPIDs: [42, 43],
            logPath: "/Users/me/Library/Logs/Gio/update.log", relaunch: relaunch
        )
    }

    func testScriptQuotesEveryPathAndWaitsForEveryPID() {
        let script = updateInstallScript(plan())
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("TARGET='/Users/me/My Apps/Gio.app'"))
        XCTAssertTrue(script.contains("STAGED='/Users/me/My Apps/.gio-update-a1B2c3/Gio.app'"))
        XCTAssertTrue(script.contains("STAGE_DIR='/Users/me/My Apps/.gio-update-a1B2c3'"))
        XCTAssertTrue(script.contains("ASIDE_TEMPLATE='/Users/me/My Apps/.gio-previous-XXXXXX'"))
        XCTAssertTrue(script.contains("LOG='/Users/me/Library/Logs/Gio/update.log'"))
        XCTAssertTrue(script.contains("for pid in 42 43; do"))
        // Paths are only ever used quoted.
        for name in ["TARGET", "STAGED", "STAGE_DIR", "ASIDE", "ASIDE_DIR", "ASIDE_TEMPLATE", "REQ"] {
            XCTAssertFalse(script.contains(" $\(name)"), name)
        }
    }

    func testRequirementIsShellQuotedAndPassedAsLiteralRequirementText() {
        let script = updateInstallScript(plan())
        XCTAssertTrue(script.contains("REQ=\(shellQuoted(requirement))\n"))
        XCTAssertTrue(script.contains(#"REQ='(identifier "dev.gio.windowmanager" and certificate leaf[subject.CN] = "Apple Development: O'\''Brien (X)") and anchor apple generic'"#))
        XCTAssertTrue(script.contains(#"/usr/bin/codesign --verify --strict --deep "-R=$REQ" "$TARGET""#))
    }

    func testAsideFolderIsCreatedExclusivelyBeforeTheInstalledAppMoves() throws {
        let script = updateInstallScript(plan())
        let mktemp = try XCTUnwrap(script.range(of: #"ASIDE_DIR="$(mktemp -d "$ASIDE_TEMPLATE")""#))
        let aside = try XCTUnwrap(script.range(of: #"ASIDE="$ASIDE_DIR/Gio.app""#))
        let move = try XCTUnwrap(script.range(of: #"mv "$TARGET" "$ASIDE""#))
        XCTAssertLessThan(mktemp.lowerBound, aside.lowerBound)
        XCTAssertLessThan(aside.lowerBound, move.lowerBound)
        // No copy fallback: the staged app sits on the target's volume, so the swap is a rename.
        XCTAssertFalse(script.contains("ditto"))
    }

    func testSwappedAppIsVerifiedAndRolledBackBeforeQuarantineIsStrippedOrGioRelaunches() throws {
        let script = updateInstallScript(plan())
        let order = [
            #"mv "$TARGET" "$ASIDE""#,
            #"mv "$STAGED" "$TARGET""#,
            #"/usr/bin/codesign --verify --strict --deep "-R=$REQ" "$TARGET""#,
            #"xattr -dr com.apple.quarantine "$TARGET""#,
            #"rm -rf "$ASIDE_DIR""#,
            #"open "$TARGET" --args"#,
        ]
        var cursor = script.startIndex
        for step in order {
            let found = try XCTUnwrap(script.range(of: step, range: cursor..<script.endIndex), step)
            cursor = found.upperBound
        }
        // The failure branch of the check restores the previous app and exits before the quarantine strip.
        let check = try XCTUnwrap(script.range(of: #"if ! /usr/bin/codesign"#))
        let close = try XCTUnwrap(script.range(of: "\nfi\n", range: check.upperBound..<script.endIndex))
        let branch = String(script[check.upperBound..<close.lowerBound])
        let restore = try XCTUnwrap(branch.range(of: #"mv "$ASIDE" "$TARGET""#))
        let remove = try XCTUnwrap(branch.range(of: #"rm -rf "$TARGET""#))
        let exit = try XCTUnwrap(branch.range(of: "exit 1"))
        XCTAssertLessThan(remove.lowerBound, restore.lowerBound)
        XCTAssertLessThan(restore.lowerBound, exit.lowerBound)
        XCTAssertFalse(branch.contains("xattr"))
        if let reopen = branch.range(of: "open \"$TARGET\"") {
            XCTAssertLessThan(restore.lowerBound, reopen.lowerBound, "only the restored app is reopened")
        }
        XCTAssertFalse(updateInstallScript(plan(relaunch: false)).contains("open \"$TARGET\""))
    }

    func testScriptNeverLogsSecretsOrTokens() {
        let script = updateInstallScript(plan()).lowercased()
        XCTAssertFalse(script.contains("token"))
        XCTAssertFalse(script.contains("authorization"))
    }

    func testUpdateRequestFromArgv() {
        XCTAssertEqual(parseUpdateRequest(["update"]), .check)
        XCTAssertEqual(parseUpdateRequest(["update", "--install"]), .install)
        XCTAssertNil(parseUpdateRequest(["update", "--bogus"]))
        XCTAssertNil(parseUpdateRequest(["status"]))
        XCTAssertNil(parseUpdateRequest([]))
    }

    func testCLIAnswers() {
        let asset = GitHubReleaseAsset(name: "Gio-0.3.0.dmg", size: 1, url: "u", browserDownloadURL: "b")
        let update = AvailableUpdate(
            version: SemanticVersion("0.3.0")!, tag: "v0.3.0", notes: "", isPrerelease: false,
            pageURL: "https://github.com/o/r/releases/tag/v0.3.0", dmg: asset, checksum: asset
        )
        XCTAssertEqual(
            describeUpdateCheck(.upToDate, runningVersion: "0.2.0"), "Gio 0.2.0 is up to date"
        )
        XCTAssertEqual(
            describeUpdateCheck(.available(update), runningVersion: "0.2.0"),
            "Gio 0.3.0 is available (running 0.2.0). Run `gio update --install` or use Update and Restart in Gio."
        )
        XCTAssertEqual(
            describeUpdateCheck(.failed(.repositoryUnavailable, update: nil), runningVersion: "0.2.0"),
            "update check failed: \(UpdateFailure.repositoryUnavailable.message)"
        )
        XCTAssertEqual(
            describeUpdateInstall(.downloading(update, progress: 0), eligibility: .installable(target: "/Applications/Gio.app")),
            "installing Gio 0.3.0: downloading; Gio quits and reopens when the new version is in place"
        )
        XCTAssertEqual(
            describeUpdateInstall(.available(update), eligibility: .notifyOnly(.buildFolder)),
            "Gio 0.3.0 is available but cannot be installed here: \(UpdateIneligibility.buildFolder.message) \(UpdateIneligibility.buildFolder.suggestion)"
        )
        XCTAssertEqual(
            describeUpdateInstall(.upToDate, eligibility: .installable(target: "/Applications/Gio.app")),
            "nothing to install: Gio \(gioVersion) is up to date"
        )
        XCTAssertTrue(
            describeUpdateInstall(.failed(.checksumMismatch, update: update), eligibility: .installable(target: "/A/Gio.app"))
                .hasPrefix("update failed: ")
        )
    }
}
