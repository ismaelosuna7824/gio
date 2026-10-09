import Foundation

/// UP-04: when Gio looks for updates.
///
/// - Launch: once, `launchDelay` after the session started (never during
///   the startup layout), skipped when a check ran within `launchMinimumGap`
///   so `gio restart` loops do not hammer GitHub.
/// - Scheduled: at most once per `interval` while running, through
///   `NSBackgroundActivityScheduler`. The system picks the moment within
///   `tolerance` (on power, idle CPU) and coalesces it with other work: no
///   timer of Gio's own wakes the CPU, which keeps the idle rule (PA-02).
/// - Manual: Check Now and `gio update`, any time Gio is not busy.
///
/// Launch and scheduled checks obey the "Automatically check for updates"
/// toggle; manual checks always run.
public struct UpdateCadence: Equatable, Sendable {
    public var launchDelay: TimeInterval
    public var interval: TimeInterval
    public var tolerance: TimeInterval
    public var launchMinimumGap: TimeInterval

    public init(launchDelay: TimeInterval, interval: TimeInterval, tolerance: TimeInterval, launchMinimumGap: TimeInterval) {
        self.launchDelay = launchDelay
        self.interval = interval
        self.tolerance = tolerance
        self.launchMinimumGap = launchMinimumGap
    }

    public static let standard = UpdateCadence(
        launchDelay: 30, interval: 24 * 3600, tolerance: 3600, launchMinimumGap: 3600
    )
}

public enum UpdateCheckTrigger: String, Sendable {
    case launch
    case scheduled
    case manual
}

public func shouldCheckForUpdates(
    trigger: UpdateCheckTrigger, automaticChecks: Bool, lastCheck: Date?, now: Date, state: UpdateState,
    cadence: UpdateCadence = .standard
) -> Bool {
    if state.isBusy {
        return false
    }
    if case .readyToInstall = state {
        return false
    }
    switch trigger {
    case .manual:
        return true
    case .launch, .scheduled:
        guard automaticChecks else {
            return false
        }
        guard let lastCheck, lastCheck <= now else {
            return true
        }
        let gap = trigger == .launch ? cadence.launchMinimumGap : cadence.interval - cadence.tolerance
        return now.timeIntervalSince(lastCheck) >= gap
    }
}
