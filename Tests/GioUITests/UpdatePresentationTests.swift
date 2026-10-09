import Foundation
@testable import GioCore
@testable import GioUI
import XCTest

/// UP-11: what the Overview row, the menu bar and the notes sheet show.
final class UpdatePresentationTests: XCTestCase {
    private var update: AvailableUpdate {
        let asset = GitHubReleaseAsset(name: "Gio-0.3.0.dmg", size: 1, url: "u", browserDownloadURL: "b")
        return AvailableUpdate(
            version: SemanticVersion("0.3.0")!, tag: "v0.3.0", notes: "# Hi", isPrerelease: false,
            pageURL: "https://github.com/o/r/releases/tag/v0.3.0", dmg: asset, checksum: asset
        )
    }

    private let installable = InstallEligibility.installable(target: "/Applications/Gio.app")

    private func row(_ state: UpdateState, eligibility: InstallEligibility? = nil) -> UpdateRowPresentation {
        updateRowPresentation(state: state, runningVersion: "0.2.0", eligibility: eligibility ?? installable)
    }

    func testIdleAndUpToDate() {
        XCTAssertEqual(row(.idle).status, "Version 0.2.0")
        XCTAssertEqual(row(.idle).action, .checkNow)
        XCTAssertEqual(row(.upToDate).status, "Gio 0.2.0 is up to date")
        XCTAssertEqual(row(.upToDate).kind, .ok)
        XCTAssertEqual(row(.checking).status, "Checking for updates…")
        XCTAssertNil(row(.checking).action)
    }

    func testAvailableOffersUpdateAndNotes() {
        let available = row(.available(update))
        XCTAssertEqual(available.status, "Gio 0.3.0 is available")
        XCTAssertEqual(available.action, .updateAndRestart)
        XCTAssertTrue(available.showsNotes)
        XCTAssertEqual(available.kind, .info)
    }

    func testIneligibleCopyOffersTheReleasePage() {
        let notify = row(.available(update), eligibility: .notifyOnly(.translocated))
        XCTAssertEqual(notify.action, .openReleasePage("https://github.com/o/r/releases/tag/v0.3.0"))
        XCTAssertEqual(notify.detail, UpdateIneligibility.translocated.message + " " + UpdateIneligibility.translocated.suggestion)
    }

    func testProgressStates() {
        XCTAssertEqual(row(.downloading(update, progress: 0.42)).progress, 0.42)
        XCTAssertEqual(row(.downloading(update, progress: 0.42)).status, "Downloading Gio 0.3.0… 42%")
        XCTAssertNil(row(.downloading(update, progress: 0.42)).action)
        XCTAssertEqual(row(.verifying(update)).status, "Verifying Gio 0.3.0…")
        XCTAssertEqual(row(.readyToInstall(update, stagedApp: "/x")).action, .updateAndRestart)
        XCTAssertEqual(row(.installing(update)).status, "Installing Gio 0.3.0; Gio will reopen…")
    }

    func testFailuresExplainAndRetry() {
        let failed = row(.failed(.checksumMismatch, update: update))
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.detail, UpdateFailure.checksumMismatch.message)
        XCTAssertEqual(failed.action, .updateAndRestart)
        let checkFailed = row(.failed(.repositoryUnavailable, update: nil))
        XCTAssertEqual(checkFailed.status, "Update check failed")
        XCTAssertEqual(checkFailed.action, .checkNow)
    }

    func testMenuTitle() {
        XCTAssertEqual(updateMenuTitle(.available(update)), "Update to v0.3.0…")
        XCTAssertEqual(updateMenuTitle(.readyToInstall(update, stagedApp: "/x")), "Update to v0.3.0…")
        XCTAssertEqual(updateMenuTitle(.failed(.checksumMismatch, update: update)), "Update to v0.3.0…")
        XCTAssertNil(updateMenuTitle(.upToDate))
        XCTAssertNil(updateMenuTitle(.downloading(update, progress: 0.1)))
        XCTAssertNil(updateMenuTitle(.failed(.rateLimited, update: nil)))
    }

    func testReleaseNoteBlocks() {
        let markdown = """
        # Gio 0.3.0

        Faster **motion** and
        fewer surprises.

        ## Fixes
        - one `fix`
        * two

        """
        XCTAssertEqual(releaseNoteBlocks(markdown), [
            .heading(level: 1, text: "Gio 0.3.0"),
            .paragraph("Faster **motion** and fewer surprises."),
            .heading(level: 2, text: "Fixes"),
            .bullet("one `fix`"),
            .bullet("two"),
        ])
        XCTAssertEqual(releaseNoteBlocks(""), [])
        XCTAssertEqual(releaseNoteBlocks("  \r\n"), [])
    }
}
