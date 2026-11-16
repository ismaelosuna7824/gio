import AppKit
import GioCore

/// TG-14: the system pattern for a Gio haptic.
func hapticPattern(for feedback: HapticFeedback) -> NSHapticFeedbackManager.FeedbackPattern {
    switch feedback {
    case .levelChange: return .levelChange
    case .alignment: return .alignment
    }
}

/// TG-14: clicks a Force Touch trackpad (nothing on other trackpads or
/// mice). Main thread only.
@MainActor
public func performTrackpadHaptic(_ feedback: HapticFeedback) {
    NSHapticFeedbackManager.defaultPerformer.perform(hapticPattern(for: feedback), performanceTime: .now)
}
