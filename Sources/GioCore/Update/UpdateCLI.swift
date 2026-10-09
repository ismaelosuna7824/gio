import Foundation

/// UP-06: `gio update` asks the running app to check; `gio update --install`
/// asks it to download, verify and install. The app answers over IPC.
public enum UpdateCLIRequest: Equatable, Sendable {
    case check
    case install
}

public func parseUpdateRequest(_ argv: [String]) -> UpdateCLIRequest? {
    guard case .success(.update(let install)) = parseCLICommand(argv) else {
        return nil
    }
    return install ? .install : .check
}

/// The answer to `gio update` once the check finished.
public func describeUpdateCheck(_ state: UpdateState, runningVersion: String) -> String {
    switch state {
    case .upToDate:
        return "Gio \(runningVersion) is up to date"
    case .available(let update):
        return "Gio \(update.version) is available (running \(runningVersion)). "
            + "Run `gio update --install` or use Update and Restart in Gio."
    case .failed(let failure, _):
        return "update check failed: \(failure.message)"
    case .readyToInstall(let update, _):
        return "Gio \(update.version) is downloaded and verified; use Update and Restart in Gio"
    case .downloading(let update, _), .verifying(let update), .installing(let update):
        return "Gio \(update.version) is being installed"
    case .idle, .checking:
        return "update check did not finish; try again"
    }
}

/// The answer to `gio update --install` once the install started (or could not).
public func describeUpdateInstall(_ state: UpdateState, eligibility: InstallEligibility) -> String {
    if case .notifyOnly(let reason) = eligibility, let update = state.update {
        return "Gio \(update.version) is available but cannot be installed here: \(reason.message) \(reason.suggestion)"
    }
    switch state {
    case .downloading(let update, _):
        return "installing Gio \(update.version): downloading; Gio quits and reopens when the new version is in place"
    case .verifying(let update), .readyToInstall(let update, _), .installing(let update):
        return "installing Gio \(update.version); Gio quits and reopens when the new version is in place"
    case .failed(let failure, _):
        return "update failed: \(failure.message)"
    case .upToDate, .idle, .checking, .available:
        return "nothing to install: Gio \(gioVersion) is up to date"
    }
}
