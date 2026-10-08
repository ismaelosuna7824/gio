import Foundation

/// PF-I: whether a focus call landed where the keyboard goes. Focus is only
/// done when the target's app is the frontmost app (the one receiving key
/// events) and that app's focused window is the target. A focused window in
/// an app that stayed in the background is not focus (live: VS Code's
/// focused window matched while OrbStack kept the keyboard).
public enum FocusLanding: String, Equatable, Sendable {
    case landed
    /// Another app (or none) is frontmost.
    case notFrontmost
    /// The target's app is frontmost but keeps another window focused.
    case windowNotFocused

    /// `focusedWindowMatches` is only read when the target's app is frontmost
    /// (it costs an Accessibility call into that app).
    public static func judge(
        targetPID: pid_t, frontmostPID: pid_t?, focusedWindowMatches: () -> Bool
    ) -> FocusLanding {
        guard frontmostPID == targetPID else {
            return .notFrontmost
        }
        return focusedWindowMatches() ? .landed : .windowNotFocused
    }
}

/// PF-I: the bounded re-check after a focus call. Activation is asynchronous,
/// so the first look may come too early; the actuator looks again every
/// `interval` until it landed or `budget` is spent, and reports the last
/// reason. Runs on the calling thread (an app's write lane or the session
/// queue, never main), which may wait this briefly.
public enum FocusLandingCheck {
    public static let budget: TimeInterval = 0.05
    public static let interval: TimeInterval = 0.005

    public enum Step: Equatable, Sendable {
        case finish(FocusLanding)
        case retry(after: TimeInterval)
    }

    /// What follows a check that saw `landing`, `elapsed` after the first one.
    public static func next(after landing: FocusLanding, elapsed: TimeInterval) -> Step {
        guard landing != .landed else {
            return .finish(.landed)
        }
        let remaining = budget - elapsed
        guard remaining > 0 else {
            return .finish(landing)
        }
        return .retry(after: min(interval, remaining))
    }

    /// Check, wait, check again until `next` finishes. `clock` and `wait` are
    /// injected (tests run on a virtual clock).
    public static func await(
        check: () -> FocusLanding, clock: () -> TimeInterval, wait: (TimeInterval) -> Void
    ) -> FocusLanding {
        let started = clock()
        while true {
            let landing = check()
            switch next(after: landing, elapsed: clock() - started) {
            case .finish(let result):
                return result
            case .retry(let delay):
                wait(delay)
            }
        }
    }
}

/// PF-I: a window that refuses focus fails once per key press that lands on
/// it (live: 32 presses onto one Xcode window). The first failure of a window
/// is logged, then at most one line per window per `period`; `admit` returns
/// the failures held back since the last line, nil to stay quiet. Calling
/// thread only (the session queue).
public struct FocusFailureLogGate: Sendable {
    public static let period: TimeInterval = 60

    private var lastLogged: [WindowID: TimeInterval] = [:]
    private var suppressed: [WindowID: Int] = [:]

    public init() {}

    public mutating func admit(_ id: WindowID, now: TimeInterval) -> Int? {
        if let last = lastLogged[id], now - last < Self.period {
            suppressed[id, default: 0] += 1
            return nil
        }
        lastLogged[id] = now
        return suppressed.removeValue(forKey: id) ?? 0
    }
}
