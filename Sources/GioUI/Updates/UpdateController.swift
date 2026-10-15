import Foundation
import GioCore
import GioMacOS

/// UP-10: everything the updater needs from the outside world, injected so
/// the orchestration is tested with fakes.
public struct UpdateDependencies: Sendable {
    public var runningVersion: String
    public var source: any UpdateReleaseSource
    public var preparer: any UpdatePreparing
    public var installer: any UpdateInstalling
    public var eligibility: @Sendable () -> InstallEligibility
    /// Processes the helper waits for: Gio and its guardian.
    public var waitPIDs: @Sendable () -> [Int32]
    public var now: @Sendable () -> Date
    public var log: @Sendable (LogLevel, String) -> Void

    public init(
        runningVersion: String, source: any UpdateReleaseSource, preparer: any UpdatePreparing,
        installer: any UpdateInstalling,
        eligibility: @escaping @Sendable () -> InstallEligibility, waitPIDs: @escaping @Sendable () -> [Int32],
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (LogLevel, String) -> Void = { _, _ in }
    ) {
        self.runningVersion = runningVersion
        self.source = source
        self.preparer = preparer
        self.installer = installer
        self.eligibility = eligibility
        self.waitPIDs = waitPIDs
        self.now = now
        self.log = log
    }

    /// The real thing: GitHub releases of `GioUpdateRepository`, hdiutil,
    /// the running app's own signature as the bar a new version must
    /// clear, and the detached installer.
    public static func live(guardianPID: @escaping @Sendable () -> Int32?) -> UpdateDependencies {
        let version = gioVersion
        let bundle = Bundle.main
        let userAgent = "Gio/\(version)"
        let signature = runningAppSignature(bundleURL: bundle.bundleURL)
        let bundleIdentifier = bundle.bundleIdentifier ?? signature.bundleIdentifier ?? "dev.gio.windowmanager"
        let requirement = updateCodeRequirement(
            designated: signature.designatedRequirement, teamIdentifier: signature.teamIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let imageRequirement = updateImageRequirement(
            teamIdentifier: signature.teamIdentifier, leafCommonName: signature.leafCommonName
        )
        let parent = (bundle.bundlePath as NSString).deletingLastPathComponent
        let eligibility = installEligibility(InstallLocationFacts(
            bundlePath: bundle.bundlePath, parentWritable: FileManager.default.isWritableFile(atPath: parent),
            runningVersion: version, teamIdentifier: signature.teamIdentifier
        ))
        let log: @Sendable (LogLevel, String) -> Void = { GioLog.record($0, $1) }
        return UpdateDependencies(
            runningVersion: version,
            source: GitHubReleaseSource(
                repository: updateRepository(infoDictionary: bundle.infoDictionary), userAgent: userAgent
            ),
            preparer: UpdatePreparer(
                downloader: URLSessionAssetDownloader(userAgent: userAgent),
                verifier: {
                    guard let requirement, let imageRequirement else {
                        return nil
                    }
                    return RequirementSignatureVerifier(requirement: requirement, imageRequirement: imageRequirement)
                },
                bundleIdentifier: bundleIdentifier, log: log
            ),
            installer: DetachedScriptInstaller(requirement: requirement),
            eligibility: { eligibility },
            waitPIDs: { [getpid()] + (guardianPID().map { [$0] } ?? []) },
            log: log
        )
    }
}

/// UP-10: the updater's state for the app (Overview row, menu bar,
/// Diagnostics toggles, `gio update`). Main actor; network and disk work
/// run in the injected adapters.
@MainActor
public final class UpdateController: ObservableObject {
    public static let automaticChecksKey = "GioUpdateAutomaticChecks"
    public static let includeBetasKey = "GioUpdateIncludeBetas"
    public static let lastCheckKey = "GioUpdateLastCheck"
    public static let activityIdentifier = "dev.gio.windowmanager.update-check"

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastCheck: Date?
    /// The release notes sheet (the Overview and the menu bar open it).
    @Published public var notesPresented = false
    @Published public var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: Self.automaticChecksKey)
        }
    }

    @Published public var includeBetas: Bool {
        didSet {
            defaults.set(includeBetas, forKey: Self.includeBetasKey)
        }
    }

    public let runningVersion: String
    public let eligibility: InstallEligibility
    private let dependencies: UpdateDependencies
    private let defaults: UserDefaults
    private let quit: @MainActor () -> Void
    private var activity: NSBackgroundActivityScheduler?

    public init(dependencies: UpdateDependencies, defaults: UserDefaults = .standard, quit: @escaping @MainActor () -> Void) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.quit = quit
        runningVersion = dependencies.runningVersion
        eligibility = dependencies.eligibility()
        automaticChecks = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        includeBetas = defaults.bool(forKey: Self.includeBetasKey)
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    public var presentation: UpdateRowPresentation {
        updateRowPresentation(state: state, runningVersion: runningVersion, eligibility: eligibility)
    }

    private func apply(_ event: UpdateEvent) {
        state = nextUpdateState(state, on: event)
    }

    // MARK: Checking

    /// Looks for a newer release when `trigger` allows it now (see
    /// `shouldCheckForUpdates`); returns the resulting state.
    @discardableResult
    public func check(trigger: UpdateCheckTrigger) async -> UpdateState {
        guard shouldCheckForUpdates(
            trigger: trigger, automaticChecks: automaticChecks, lastCheck: lastCheck, now: dependencies.now(), state: state
        ) else {
            return state
        }
        apply(.checkStarted)
        let result = await dependencies.source.fetchReleases()
        let finished = dependencies.now()
        lastCheck = finished
        defaults.set(finished, forKey: Self.lastCheckKey)
        switch result {
        case .success(let releases):
            let running = SemanticVersion(runningVersion) ?? SemanticVersion(major: 0, minor: 0, patch: 0, prerelease: ["dev"])
            apply(.checked(selectUpdate(
                from: releases, running: running,
                includePrereleases: includesPrereleases(runningVersion: runningVersion, includeBetas: includeBetas)
            )))
        case .failure(let failure):
            apply(.failed(failure))
        }
        dependencies.log(.info, "update check trigger=\(trigger.rawValue) result=\(logSummary(state))")
        return state
    }

    public func checkNow() {
        Task { await check(trigger: .manual) }
    }

    /// Launch check after `launchDelay`, then the system-scheduled daily
    /// check (`NSBackgroundActivityScheduler`: no timer of Gio's own; the
    /// system runs it when convenient). Both obey the toggle at fire time.
    public func startAutomaticChecks(cadence: UpdateCadence = .standard) {
        guard activity == nil else {
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cadence.launchDelay * 1_000_000_000))
            await self?.check(trigger: .launch)
        }
        let activity = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        activity.repeats = true
        activity.interval = cadence.interval
        activity.tolerance = cadence.tolerance
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            nonisolated(unsafe) let completion = completion
            Task { @MainActor in
                await self?.check(trigger: .scheduled)
                completion(.finished)
            }
        }
        self.activity = activity
    }

    public func stopAutomaticChecks() {
        activity?.invalidate()
        activity = nil
    }

    // MARK: Installing

    /// Update and Restart: download, verify, stage, then install and quit.
    /// Returns the running task, or nil when nothing started (no update,
    /// busy, or this copy cannot replace itself: the state says why).
    @discardableResult
    public func startUpdate() -> Task<Void, Never>? {
        if case .readyToInstall = state {
            installAndQuit()
            return nil
        }
        guard let update = state.update, !state.isBusy else {
            return nil
        }
        guard case .installable(let target) = eligibility else {
            if case .notifyOnly(let reason) = eligibility {
                apply(.failed(.notEligible(reason)))
                dependencies.log(.info, "update \(update.version) not installed: \(reason.rawValue)")
            }
            return nil
        }
        apply(.downloadStarted)
        dependencies.log(.info, "update \(update.version) download started")
        return Task { await prepare(update, target: target) }
    }

    public func updateAndRestart() async {
        await startUpdate()?.value
    }

    private func prepare(_ update: AvailableUpdate, target: String) async {
        let result = await dependencies.preparer.prepare(
            update, target: target,
            progress: { [weak self] progress in
                Task { @MainActor in self?.apply(.progressed(progress)) }
            },
            verifying: { [weak self] in
                Task { @MainActor in self?.apply(.downloaded) }
            }
        )
        switch result {
        case .success(let staged):
            apply(.downloaded)
            apply(.staged(staged))
            installAndQuit()
        case .failure(let failure):
            apply(.failed(failure))
        }
    }

    /// Starts the detached helper, then quits through the normal path
    /// (windows restored, guardian told `clean`); the helper swaps the
    /// bundles once Gio and the guardian exited and reopens Gio.
    private func installAndQuit() {
        guard case .readyToInstall(let update, let staged) = state, case .installable(let target) = eligibility else {
            return
        }
        apply(.installStarted)
        switch dependencies.installer.install(stagedApp: staged, target: target, waitPIDs: dependencies.waitPIDs()) {
        case .success:
            dependencies.log(.info, "update \(update.version) installing; quitting for the helper")
            quit()
        case .failure(let failure):
            try? FileManager.default.removeItem(atPath: updateStagingDirectory(ofStagedApp: staged) ?? staged)
            apply(.failed(failure))
            dependencies.log(.warn, "update \(update.version) installer failed: \(failure)")
        }
    }

    // MARK: gio update

    /// `gio update [--install]` over IPC. Blocks the calling (IPC) thread
    /// until the answer is ready or `timeout` passes. Never call it on the
    /// main thread: the work runs there.
    public nonisolated func answerCLI(_ request: UpdateCLIRequest, timeout: TimeInterval = 45) -> String {
        let answer = CLIAnswer()
        Task { @MainActor [weak self] in
            answer.finish(await self?.respond(to: request) ?? "Gio is shutting down")
        }
        return answer.wait(timeout: timeout) ?? "the update request is still running; see Gio's Overview"
    }

    private func respond(to request: UpdateCLIRequest) async -> String {
        switch request {
        case .check:
            return describeUpdateCheck(await check(trigger: .manual), runningVersion: runningVersion)
        case .install:
            if state.update == nil {
                await check(trigger: .manual)
            }
            if case .installable = eligibility {
                startUpdate()
            }
            return describeUpdateInstall(state, eligibility: eligibility)
        }
    }

    private func logSummary(_ state: UpdateState) -> String {
        switch state {
        case .upToDate: return "upToDate"
        case .available(let update): return "available version=\(update.version)"
        case .failed(let failure, _): return "failed \(failure)"
        default: return "\(state)"
        }
    }
}

/// One answer handed from the main actor to the blocked IPC thread.
private final class CLIAnswer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var text: String?

    func finish(_ value: String) {
        lock.withLock { text = value }
        done.signal()
    }

    func wait(timeout: TimeInterval) -> String? {
        guard done.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        return lock.withLock { text }
    }
}
