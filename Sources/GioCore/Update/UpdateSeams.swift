import Foundation

/// UP-07: where releases come from (GitHub in the app, fakes in tests).
public protocol UpdateReleaseSource: Sendable {
    func fetchReleases() async -> Result<[GitHubRelease], UpdateFailure>
}

/// UP-08: download, verify and stage an update next to `target`; returns
/// the staged app's path. `verifying` fires once the download finished.
public protocol UpdatePreparing: Sendable {
    func prepare(
        _ update: AvailableUpdate, target: String, progress: @escaping @Sendable (Double) -> Void,
        verifying: @escaping @Sendable () -> Void
    ) async -> Result<String, UpdateFailure>
}

/// UP-05: start the detached helper that swaps the bundles once `waitPIDs` exited.
public protocol UpdateInstalling: Sendable {
    func install(stagedApp: String, target: String, waitPIDs: [Int32]) -> Result<Void, UpdateFailure>
}
