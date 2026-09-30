/// Why a layout pass is written without motion.
public enum InstantPlacementReason: String, Equatable, Sendable {
    /// First layout of the session (launch, `gio restart`): windows go
    /// straight to their tiles instead of flying from where they were.
    case startup
    /// Accessibility regained: the rebuilt session places everything at once.
    case permission
    /// A mouse button abandoned the running motion; the deferred pass after
    /// release lands instantly.
    case mouse
}

public enum InstantPlacementDecision: Equatable, Sendable {
    case animate
    /// Instant; the reason is nil when the pass simply did not ask to animate.
    case instant(InstantPlacementReason?)
}

/// One-shot "next pass is instant" latch. Armed for `.startup` when the
/// session is created; consumed by the next layout pass, whatever it asked.
/// A pass that is deferred (mouse down) or coalesced keeps the latch armed
/// until a pass actually runs. The first reason armed wins.
public struct InstantPlacementGate: Sendable {
    private var armed: InstantPlacementReason?

    public init(armed: InstantPlacementReason? = .startup) {
        self.armed = armed
    }

    public var isArmed: Bool { armed != nil }

    public mutating func arm(_ reason: InstantPlacementReason) {
        if armed == nil {
            armed = reason
        }
    }

    public mutating func decide(requested: Bool) -> InstantPlacementDecision {
        if let reason = armed {
            armed = nil
            return .instant(reason)
        }
        return requested ? .animate : .instant(nil)
    }
}

public func instantPlacementLogLine(_ reason: InstantPlacementReason) -> String {
    "layout instant reason=\(reason.rawValue)"
}
