import CoreGraphics

/// PA-04: publishes the focus ring only when what the overlay draws changed:
/// visibility, style, or the frame by at least `threshold` points on any edge
/// (measured against the last published frame, so slow drift still lands).
public struct FocusRingPublishGate: Sendable {
    public let threshold: CGFloat
    private var last: FocusRingState?

    public init(threshold: CGFloat = 1) {
        self.threshold = threshold
    }

    public mutating func shouldPublish(_ state: FocusRingState) -> Bool {
        defer {
            if lastNeedsUpdate(state) {
                last = state
            }
        }
        return lastNeedsUpdate(state)
    }

    public mutating func reset() {
        last = nil
    }

    private func lastNeedsUpdate(_ state: FocusRingState) -> Bool {
        guard let last else {
            return true
        }
        switch (last, state) {
        case (.hidden, .hidden):
            return false
        case (.shown(let old), .shown(let new)):
            guard old.width == new.width, old.color == new.color else {
                return true
            }
            return abs(old.frame.origin.x - new.frame.origin.x) >= threshold
                || abs(old.frame.origin.y - new.frame.origin.y) >= threshold
                || abs(old.frame.width - new.frame.width) >= threshold
                || abs(old.frame.height - new.frame.height) >= threshold
        default:
            return true
        }
    }
}
