@testable import GioCore
import XCTest

/// UP-04: the update state machine and the automatic check cadence.
final class UpdateStateTests: XCTestCase {
    private let asset = GitHubReleaseAsset(name: "Gio-0.3.0.dmg", size: 10, url: "u", browserDownloadURL: "b")
    private let sum = GitHubReleaseAsset(name: "Gio-0.3.0.dmg.sha256", size: 1, url: "u2", browserDownloadURL: "b2")
    private var update: AvailableUpdate {
        AvailableUpdate(
            version: SemanticVersion("0.3.0")!, tag: "v0.3.0", notes: "n", isPrerelease: false,
            pageURL: nil, dmg: asset, checksum: sum
        )
    }

    func testHappyPath() {
        var state = UpdateState.idle
        state = nextUpdateState(state, on: .checkStarted)
        XCTAssertEqual(state, .checking)
        XCTAssertTrue(state.isBusy)
        state = nextUpdateState(state, on: .checked(.available(update)))
        XCTAssertEqual(state, .available(update))
        XCTAssertFalse(state.isBusy)
        state = nextUpdateState(state, on: .downloadStarted)
        XCTAssertEqual(state, .downloading(update, progress: 0))
        state = nextUpdateState(state, on: .progressed(0.5))
        XCTAssertEqual(state, .downloading(update, progress: 0.5))
        state = nextUpdateState(state, on: .progressed(7))
        XCTAssertEqual(state, .downloading(update, progress: 1))
        state = nextUpdateState(state, on: .downloaded)
        XCTAssertEqual(state, .verifying(update))
        state = nextUpdateState(state, on: .staged("/Applications/.Gio-0.3.0-update.app"))
        XCTAssertEqual(state, .readyToInstall(update, stagedApp: "/Applications/.Gio-0.3.0-update.app"))
        state = nextUpdateState(state, on: .installStarted)
        XCTAssertEqual(state, .installing(update))
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.update, update)
    }

    func testUpToDate() {
        XCTAssertEqual(nextUpdateState(.checking, on: .checked(.upToDate)), .upToDate)
    }

    func testFailuresKeepTheUpdateForRetry() {
        let failed = nextUpdateState(.verifying(update), on: .failed(.checksumMismatch))
        XCTAssertEqual(failed, .failed(.checksumMismatch, update: update))
        XCTAssertEqual(nextUpdateState(failed, on: .downloadStarted), .downloading(update, progress: 0))
        XCTAssertEqual(nextUpdateState(.checking, on: .failed(.repositoryUnavailable)), .failed(.repositoryUnavailable, update: nil))
        // Nothing to download after a failed check.
        let checkFailed = UpdateState.failed(.repositoryUnavailable, update: nil)
        XCTAssertEqual(nextUpdateState(checkFailed, on: .downloadStarted), checkFailed)
    }

    func testInvalidTransitionsAreIgnored() {
        XCTAssertEqual(nextUpdateState(.idle, on: .downloadStarted), .idle)
        XCTAssertEqual(nextUpdateState(.idle, on: .checked(.upToDate)), .idle)
        XCTAssertEqual(nextUpdateState(.available(update), on: .installStarted), .available(update))
        XCTAssertEqual(nextUpdateState(.checking, on: .checkStarted), .checking)
        XCTAssertEqual(nextUpdateState(.downloading(update, progress: 0.2), on: .checkStarted), .downloading(update, progress: 0.2))
        XCTAssertEqual(nextUpdateState(.available(update), on: .progressed(0.3)), .available(update))
        // A staged update is not thrown away by another check.
        let ready = UpdateState.readyToInstall(update, stagedApp: "/x")
        XCTAssertEqual(nextUpdateState(ready, on: .checkStarted), ready)
        XCTAssertEqual(nextUpdateState(.installing(update), on: .failed(.checksumMismatch)), .failed(.checksumMismatch, update: update))
    }

    func testChecksAllowedFromRestingStates() {
        for state in [UpdateState.idle, .upToDate, .available(update), .failed(.rateLimited, update: nil)] {
            XCTAssertEqual(nextUpdateState(state, on: .checkStarted), .checking, "\(state)")
        }
    }

    func testEveryFailureHasAMessage() {
        let failures: [UpdateFailure] = [
            .network("offline"), .repositoryUnavailable, .rateLimited,
            .httpStatus(500), .malformedResponse, .downloadFailed("x"), .checksumUnreadable, .checksumMismatch,
            .mountFailed("x"), .appMissing, .bundleMismatch("x"), .signatureRejected("x"),
            .notEligible(.buildFolder), .stagingFailed("x"), .installerFailed("x"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure)")
        }
        XCTAssertTrue(UpdateFailure.repositoryUnavailable.message.contains("private or not found"))
    }

    // MARK: Cadence

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testManualChecksAlwaysRunUnlessBusy() {
        XCTAssertTrue(shouldCheckForUpdates(
            trigger: .manual, automaticChecks: false, lastCheck: start, now: start, state: .upToDate
        ))
        XCTAssertFalse(shouldCheckForUpdates(
            trigger: .manual, automaticChecks: true, lastCheck: nil, now: start, state: .checking
        ))
        XCTAssertFalse(shouldCheckForUpdates(
            trigger: .manual, automaticChecks: true, lastCheck: nil, now: start,
            state: .readyToInstall(update, stagedApp: "/x")
        ))
    }

    func testAutomaticChecksHonorTheToggle() {
        for trigger in [UpdateCheckTrigger.launch, .scheduled] {
            XCTAssertFalse(shouldCheckForUpdates(
                trigger: trigger, automaticChecks: false, lastCheck: nil, now: start, state: .idle
            ))
            XCTAssertTrue(shouldCheckForUpdates(
                trigger: trigger, automaticChecks: true, lastCheck: nil, now: start, state: .idle
            ))
        }
    }

    func testScheduledChecksRunAtMostDaily() {
        let cadence = UpdateCadence.standard
        XCTAssertEqual(cadence.interval, 24 * 3600)
        XCTAssertEqual(cadence.launchDelay, 30)
        XCTAssertFalse(shouldCheckForUpdates(
            trigger: .scheduled, automaticChecks: true, lastCheck: start,
            now: start.addingTimeInterval(6 * 3600), state: .upToDate
        ))
        // The system may fire early within its tolerance.
        XCTAssertTrue(shouldCheckForUpdates(
            trigger: .scheduled, automaticChecks: true, lastCheck: start,
            now: start.addingTimeInterval(cadence.interval - cadence.tolerance), state: .upToDate
        ))
        // A clock that went backwards does not block checks forever.
        XCTAssertTrue(shouldCheckForUpdates(
            trigger: .scheduled, automaticChecks: true, lastCheck: start.addingTimeInterval(9_999_999),
            now: start, state: .upToDate
        ))
    }

    func testLaunchChecksSkipRestartLoops() {
        XCTAssertFalse(shouldCheckForUpdates(
            trigger: .launch, automaticChecks: true, lastCheck: start,
            now: start.addingTimeInterval(600), state: .idle
        ))
        XCTAssertTrue(shouldCheckForUpdates(
            trigger: .launch, automaticChecks: true, lastCheck: start,
            now: start.addingTimeInterval(UpdateCadence.standard.launchMinimumGap), state: .idle
        ))
    }
}
