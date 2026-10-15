import Foundation

/// UP-04: why an update step stopped. Messages are for people and logs:
/// they never carry response bodies or window titles.
public enum UpdateFailure: Error, Equatable, Sendable {
    case network(String)
    /// 404: GitHub answers 404 for private repositories too.
    case repositoryUnavailable
    case rateLimited
    case httpStatus(Int)
    case malformedResponse
    case downloadFailed(String)
    case checksumUnreadable
    case checksumMismatch
    case mountFailed(String)
    case appMissing
    case bundleMismatch(String)
    case signatureRejected(String)
    case notEligible(UpdateIneligibility)
    case stagingFailed(String)
    case installerFailed(String)

    public var message: String {
        switch self {
        case .network(let detail): return "GitHub is unreachable (\(detail))."
        case .repositoryUnavailable: return "The release repository is private or not found."
        case .rateLimited: return "GitHub's rate limit was reached. Gio tries again later."
        case .httpStatus(let code): return "GitHub answered HTTP \(code)."
        case .malformedResponse: return "GitHub's answer could not be read."
        case .downloadFailed(let detail): return "The download failed (\(detail))."
        case .checksumUnreadable: return "The release checksum file could not be read."
        case .checksumMismatch: return "The download does not match its published checksum. Nothing was installed."
        case .mountFailed(let detail): return "The disk image could not be opened (\(detail))."
        case .appMissing: return "The disk image does not contain Gio.app."
        case .bundleMismatch(let detail): return "The downloaded app is not this Gio release (\(detail)). Nothing was installed."
        case .signatureRejected(let detail):
            return "The downloaded app is not signed by the same developer (\(detail)). Nothing was installed."
        case .notEligible(let reason): return reason.message + " " + reason.suggestion
        case .stagingFailed(let detail): return "The new version could not be prepared (\(detail))."
        case .installerFailed(let detail): return "The installer could not start (\(detail))."
        }
    }
}

/// idle → checking → upToDate | available → downloading → verifying →
/// readyToInstall → installing; any step may end in `failed`.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
    case downloading(AvailableUpdate, progress: Double)
    case verifying(AvailableUpdate)
    /// The verified app sits at `stagedApp`, next to the installed one.
    case readyToInstall(AvailableUpdate, stagedApp: String)
    case installing(AvailableUpdate)
    /// `update` is kept so the user can retry the download.
    case failed(UpdateFailure, update: AvailableUpdate?)

    public var update: AvailableUpdate? {
        switch self {
        case .idle, .checking, .upToDate: return nil
        case .available(let update), .downloading(let update, _), .verifying(let update),
             .readyToInstall(let update, _), .installing(let update):
            return update
        case .failed(_, let update): return update
        }
    }

    /// A step is running; nothing else may start.
    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

public enum UpdateEvent: Equatable, Sendable {
    case checkStarted
    case checked(UpdateSelection)
    case downloadStarted
    case progressed(Double)
    case downloaded
    case staged(String)
    case installStarted
    case failed(UpdateFailure)
}

/// The transition table. An event that does not apply to the current state
/// returns it unchanged (a late progress tick, a double click).
public func nextUpdateState(_ state: UpdateState, on event: UpdateEvent) -> UpdateState {
    switch (state, event) {
    case (.idle, .checkStarted), (.upToDate, .checkStarted), (.available, .checkStarted), (.failed, .checkStarted):
        return .checking
    case (.checking, .checked(.upToDate)):
        return .upToDate
    case (.checking, .checked(.available(let update))):
        return .available(update)
    case (.available(let update), .downloadStarted), (.failed(_, let update?), .downloadStarted):
        return .downloading(update, progress: 0)
    case (.downloading(let update, _), .progressed(let progress)):
        return .downloading(update, progress: min(max(progress, 0), 1))
    case (.downloading(let update, _), .downloaded):
        return .verifying(update)
    case (.verifying(let update), .staged(let path)):
        return .readyToInstall(update, stagedApp: path)
    case (.readyToInstall(let update, _), .installStarted):
        return .installing(update)
    case (_, .failed(let failure)):
        return .failed(failure, update: state.update)
    default:
        return state
    }
}
