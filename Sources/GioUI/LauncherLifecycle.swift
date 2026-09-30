import Foundation

/// Where a launcher summon came from (logged, never a title).
public enum LauncherSummonSource: String, Sendable {
    case hotkey, menu
}

/// Why the launcher closed (logged).
public enum LauncherDismissReason: String, Sendable {
    case escape, toggle, resignKey, action
}

/// What a summon does given the current presentation.
public enum LauncherToggle: Equatable, Sendable {
    case show, dismiss
}

/// What a `windowDidResignKey` does.
public enum LauncherResignDecision: Equatable, Sendable {
    /// Not presented or already fading out.
    case ignore
    /// Lost key right after showing (activation churn, the hotkey's own
    /// key-up): take it back instead of vanishing.
    case reclaimKey
    /// The user moved on (another app or window took key).
    case dismiss
}

/// FI-09: the launcher panel's presentation state, pure so it is tested.
/// Every show and dismiss bumps a generation token, so an animation
/// completion from an earlier show or fade-out can never order out, or
/// force opaque, the panel of a later one. Visibility for the toggle is
/// derived from the real panel (`panelVisible`) plus this state, never from
/// a flag alone.
public struct LauncherLifecycle: Equatable, Sendable {
    /// A resign-key this soon after showing is not the user leaving.
    public static let resignGrace: TimeInterval = 0.25

    public struct AppearPlan: Equatable, Sendable {
        public let duration: TimeInterval
        /// Points the panel slides down from; 0 with Reduce Motion (fade only).
        public let offset: CGFloat
        /// When the panel is forced to its final alpha and frame even if the
        /// animation completion never runs (interrupted, window hidden).
        public let safetyDeadline: TimeInterval
    }

    public static func appearPlan(reduceMotion: Bool) -> AppearPlan {
        let duration = reduceMotion ? 0.12 : 0.18
        return AppearPlan(duration: duration, offset: reduceMotion ? 0 : 8, safetyDeadline: duration + 0.1)
    }

    public private(set) var generation = 0
    public private(set) var shownAt: TimeInterval?
    public private(set) var dismissing = false

    public init() {}

    /// Presented and not fading out.
    public var isPresented: Bool {
        shownAt != nil && !dismissing
    }

    public func toggle(panelVisible: Bool) -> LauncherToggle {
        panelVisible && isPresented ? .dismiss : .show
    }

    /// Returns the token the appear completion and safety net must match.
    public mutating func beginShow(at now: TimeInterval) -> Int {
        generation += 1
        shownAt = now
        dismissing = false
        return generation
    }

    /// Nil when nothing is presented or a fade-out already runs.
    public mutating func beginDismiss() -> Int? {
        guard isPresented else {
            return nil
        }
        generation += 1
        dismissing = true
        return generation
    }

    /// True when the fade-out that returned `token` should order the panel out.
    public mutating func finishDismiss(_ token: Int) -> Bool {
        guard token == generation, dismissing else {
            return false
        }
        shownAt = nil
        dismissing = false
        return true
    }

    /// True when the show that returned `token` is still current, so its end
    /// state (alpha 1, final frame) should be applied. Idempotent.
    public func finishAppear(_ token: Int) -> Bool {
        token == generation && isPresented
    }

    public func resignDecision(now: TimeInterval) -> LauncherResignDecision {
        guard let shownAt, !dismissing else {
            return .ignore
        }
        return now - shownAt < Self.resignGrace ? .reclaimKey : .dismiss
    }
}
