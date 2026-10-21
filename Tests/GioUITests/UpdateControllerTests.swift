import Foundation
@testable import GioCore
@testable import GioMacOS
@testable import GioUI
import XCTest

/// UP-10: the updater's orchestration over fakes: checks, channels,
/// eligibility, download/verify/install, quit, and the `gio update` bridge.
@MainActor
final class UpdateControllerTests: XCTestCase {
    final class FakeSource: UpdateReleaseSource, @unchecked Sendable {
        var result: Result<[GitHubRelease], UpdateFailure> = .success([])
        private(set) var fetches = 0
        func fetchReleases() async -> Result<[GitHubRelease], UpdateFailure> {
            fetches += 1
            return result
        }
    }

    final class FakePreparer: UpdatePreparing, @unchecked Sendable {
        var result: Result<String, UpdateFailure> = .success("/Applications/.Gio-0.3.0-update.app")
        private(set) var prepared: [(SemanticVersion, String)] = []
        func prepare(
            _ update: AvailableUpdate, target: String, progress: @escaping @Sendable (Double) -> Void,
            verifying: @escaping @Sendable () -> Void
        ) async -> Result<String, UpdateFailure> {
            prepared.append((update.version, target))
            progress(0.5)
            verifying()
            return result
        }
    }

    final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
        var result: Result<Void, UpdateFailure> = .success(())
        private(set) var calls: [(String, String, [Int32])] = []
        func install(stagedApp: String, target: String, waitPIDs: [Int32]) -> Result<Void, UpdateFailure> {
            calls.append((stagedApp, target, waitPIDs))
            return result
        }
    }

    /// A virtual clock the fakes share.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 2_000_000)
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private let suite = "gio-update-tests-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suite)!
    private let source = FakeSource()
    private let preparer = FakePreparer()
    private let installer = FakeInstaller()
    private var quits = 0
    private let clock = Clock()
    private var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func release(_ tag: String, prerelease: Bool = false) -> GitHubRelease {
        let version = SemanticVersion(tag)!
        let names = updateAssetNames(for: version)
        return GitHubRelease(
            tagName: tag, draft: false, prerelease: prerelease, body: "notes for \(tag)",
            htmlURL: "https://github.com/o/r/releases/tag/\(tag)",
            assets: [
                GitHubReleaseAsset(name: names.dmg, size: 10, url: "a", browserDownloadURL: "b"),
                GitHubReleaseAsset(name: names.checksum, size: 1, url: "c", browserDownloadURL: "d"),
            ]
        )
    }

    private func controller(
        version: String = "0.2.0", eligibility: InstallEligibility = .installable(target: "/Applications/Gio.app")
    ) -> UpdateController {
        let clock = clock
        return UpdateController(
            dependencies: UpdateDependencies(
                runningVersion: version, source: source, preparer: preparer, installer: installer,
                eligibility: { eligibility }, waitPIDs: { [111, 222] },
                now: { clock.now }
            ),
            defaults: defaults, quit: { [unowned self] in quits += 1 }
        )
    }

    /// PA-16: the install eligibility (code-signature and folder facts) is
    /// read on first use, not when the controller is made at launch.
    func testEligibilityIsReadOnFirstUseOnly() {
        final class Counter: @unchecked Sendable {
            var calls = 0
        }
        let counter = Counter()
        let updates = UpdateController(
            dependencies: UpdateDependencies(
                runningVersion: "0.2.0", source: source, preparer: preparer, installer: installer,
                eligibility: {
                    counter.calls += 1
                    return .notifyOnly(.buildFolder)
                },
                waitPIDs: { [] }
            ),
            defaults: defaults, quit: {}
        )
        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(updates.eligibility, .notifyOnly(.buildFolder))
        _ = updates.presentation
        XCTAssertEqual(counter.calls, 1)
    }

    func testManualCheckFindsAnUpdateAndRemembersTheTime() async {
        source.result = .success([release("v0.3.0"), release("v0.2.0")])
        let updates = controller()
        let state = await updates.check(trigger: .manual)
        XCTAssertEqual(state.update?.version, SemanticVersion("0.3.0"))
        XCTAssertEqual(updates.state, state)
        XCTAssertEqual(updates.lastCheck, now)
        XCTAssertEqual(controller().lastCheck, now, "persisted in UserDefaults")
    }

    func testUpToDateAndPrivateRepository() async {
        source.result = .success([release("v0.2.0")])
        let updates = controller()
        let first = await updates.check(trigger: .manual)
        XCTAssertEqual(first, .upToDate)
        source.result = .failure(.repositoryUnavailable)
        let second = await updates.check(trigger: .manual)
        XCTAssertEqual(second, .failed(.repositoryUnavailable, update: nil))
    }

    func testBetasFollowThePreference() async {
        source.result = .success([release("v0.3.0-beta.1", prerelease: true)])
        let updates = controller()
        let stable = await updates.check(trigger: .manual)
        XCTAssertEqual(stable, .upToDate)
        updates.includeBetas = true
        let beta = await updates.check(trigger: .manual)
        XCTAssertEqual(beta.update?.version, SemanticVersion("0.3.0-beta.1"))
        XCTAssertTrue(controller().includeBetas, "persisted")
    }

    func testAutomaticChecksObeyTheToggleAndCadence() async {
        source.result = .success([])
        let updates = controller()
        XCTAssertTrue(updates.automaticChecks, "on by default")
        updates.automaticChecks = false
        _ = await updates.check(trigger: .launch)
        XCTAssertEqual(source.fetches, 0)
        XCTAssertFalse(controller().automaticChecks, "persisted")
        updates.automaticChecks = true
        _ = await updates.check(trigger: .launch)
        XCTAssertEqual(source.fetches, 1)
        now = now.addingTimeInterval(3600)
        _ = await updates.check(trigger: .scheduled)
        XCTAssertEqual(source.fetches, 1, "at most daily")
    }

    func testUpdateAndRestartInstallsThenQuits() async {
        source.result = .success([release("v0.3.0")])
        let updates = controller()
        _ = await updates.check(trigger: .manual)
        await updates.updateAndRestart()
        XCTAssertEqual(preparer.prepared.first?.1, "/Applications/Gio.app")
        XCTAssertEqual(installer.calls.count, 1)
        XCTAssertEqual(installer.calls.first?.0, "/Applications/.Gio-0.3.0-update.app")
        XCTAssertEqual(installer.calls.first?.2, [111, 222])
        XCTAssertEqual(updates.state, .installing(updates.state.update!))
        XCTAssertEqual(quits, 1)
    }

    func testChecksumMismatchRefusesWithoutInstalling() async {
        source.result = .success([release("v0.3.0")])
        preparer.result = .failure(.checksumMismatch)
        let updates = controller()
        _ = await updates.check(trigger: .manual)
        await updates.updateAndRestart()
        XCTAssertEqual(updates.state, .failed(.checksumMismatch, update: updates.state.update))
        XCTAssertNotNil(updates.state.update, "kept for a retry")
        XCTAssertTrue(installer.calls.isEmpty)
        XCTAssertEqual(quits, 0)
    }

    func testSignatureRefusalStopsTheInstall() async {
        source.result = .success([release("v0.3.0")])
        preparer.result = .failure(.signatureRejected("different developer or bundle"))
        let updates = controller()
        _ = await updates.check(trigger: .manual)
        await updates.updateAndRestart()
        guard case .failed(.signatureRejected, _) = updates.state else {
            return XCTFail("expected a refusal, got \(updates.state)")
        }
        XCTAssertTrue(installer.calls.isEmpty)
        XCTAssertEqual(quits, 0)
    }

    func testIneligibleCopyOnlyNotifies() async {
        source.result = .success([release("v0.3.0")])
        let updates = controller(eligibility: .notifyOnly(.buildFolder))
        _ = await updates.check(trigger: .manual)
        await updates.updateAndRestart()
        XCTAssertEqual(updates.state, .failed(.notEligible(.buildFolder), update: updates.state.update))
        XCTAssertTrue(preparer.prepared.isEmpty)
        XCTAssertEqual(quits, 0)
    }

    func testInstallerFailureDoesNotQuit() async {
        source.result = .success([release("v0.3.0")])
        installer.result = .failure(.installerFailed("spawn error 1"))
        let updates = controller()
        _ = await updates.check(trigger: .manual)
        await updates.updateAndRestart()
        XCTAssertEqual(updates.state, .failed(.installerFailed("spawn error 1"), update: updates.state.update))
        XCTAssertEqual(quits, 0)
    }

    func testCLICheckAnswersFromABackgroundThread() async {
        source.result = .success([release("v0.3.0")])
        let updates = controller()
        let answer = await Task.detached { updates.answerCLI(.check, timeout: 5) }.value
        XCTAssertEqual(answer, describeUpdateCheck(updates.state, runningVersion: "0.2.0"))
        XCTAssertTrue(answer.contains("0.3.0 is available"))
    }

    func testCLIInstallStartsTheDownload() async {
        source.result = .success([release("v0.3.0")])
        let updates = controller()
        let answer = await Task.detached { updates.answerCLI(.install, timeout: 5) }.value
        XCTAssertTrue(answer.hasPrefix("installing Gio 0.3.0"), answer)
        // The download continues after the answer left.
        for _ in 0..<200 where quits == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(preparer.prepared.count, 1)
        XCTAssertEqual(quits, 1)
    }

    func testCLIInstallOnIneligibleCopyExplains() async {
        source.result = .success([release("v0.3.0")])
        let updates = controller(eligibility: .notifyOnly(.developmentBuild))
        let answer = await Task.detached { updates.answerCLI(.install, timeout: 5) }.value
        XCTAssertTrue(answer.contains("cannot be installed here"), answer)
        XCTAssertTrue(preparer.prepared.isEmpty)
    }
}
