import CoreGraphics
import Foundation

/// PA-04: frames Gio itself placed and verified (or read) for a window. The
/// final exact pass skips the two-call AX read of a window whose desired
/// frame equals its trusted frame, above all parked and hidden windows that
/// only need to stay put. Pure value type; the session host owns the
/// invalidation rules:
/// - a non-echo moved/resized event for the window (user drag, app resize),
/// - re-registration, purge, and a failed or vanished report,
/// - the start of a motion that moves it (motion frames are unverified).
public struct TrustedFrames: Sendable {
    /// Same 1 pt tolerance the reconciler uses to call a frame correct.
    public static let tolerance: CGFloat = 1

    private var frames: [WindowID: CGRect] = [:]

    public init() {}

    public var count: Int { frames.count }

    public func frame(of id: WindowID) -> CGRect? {
        frames[id]
    }

    public mutating func trust(_ id: WindowID, frame: CGRect) {
        frames[id] = frame
    }

    public mutating func invalidate(_ id: WindowID) {
        frames.removeValue(forKey: id)
    }

    public mutating func invalidate(_ ids: some Sequence<WindowID>) {
        for id in ids {
            frames.removeValue(forKey: id)
        }
    }

    public mutating func removeAll() {
        frames.removeAll()
    }

    /// True when the trusted frame already satisfies `desired`: no read, no
    /// write. An untrusted window is always read.
    public func canSkipRead(_ id: WindowID, desired: CGRect, tolerance: CGFloat = TrustedFrames.tolerance) -> Bool {
        guard let trusted = frames[id] else {
            return false
        }
        return abs(trusted.origin.x - desired.origin.x) <= tolerance
            && abs(trusted.origin.y - desired.origin.y) <= tolerance
            && abs(trusted.width - desired.width) <= tolerance
            && abs(trusted.height - desired.height) <= tolerance
    }

    /// After a settle pass: windows that ended applied, parked or already
    /// correct are trusted at their desired frame; failed and vanished ones
    /// lose their trust.
    public mutating func recordSettle(
        report: ReconcileReport, visible: [WindowID: CGRect], parked: [WindowID: ParkedTarget]
    ) {
        for id in report.applied + report.alreadyCorrect + report.parked {
            if let target = parked[id] {
                frames[id] = target.frame
            } else if let frame = visible[id] {
                frames[id] = frame
            }
        }
        invalidate(report.failed)
        invalidate(report.vanished)
    }
}

/// PA-04 render check scope: the visible targets that were written or
/// animated in this settle and whose frame the settle already has. Parked,
/// failed and untouched windows are not checked; the frames returned are the
/// ones the settle read or verified, so the check needs no AX read.
public func renderCheckFrames(
    candidates: Set<WindowID>, visible: [WindowID: CGRect], settled: [WindowID: CGRect]
) -> [WindowID: CGRect] {
    var frames: [WindowID: CGRect] = [:]
    for id in candidates where visible[id] != nil {
        if let frame = settled[id] {
            frames[id] = frame
        }
    }
    return frames
}

/// PA-04: single-entry memo for a plan derived purely from an equatable key
/// (membership, display frames, frames of the involved windows). A changed key
/// recomputes; `invalidate()` forces a recompute for events the key cannot
/// see (config reload).
public struct PlanMemo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    public init() {}

    public mutating func value(for key: Key, compute: () -> Value) -> Value {
        if let cached, cached.key == key {
            return cached.value
        }
        let value = compute()
        cached = (key, value)
        return value
    }

    public mutating func invalidate() {
        cached = nil
    }
}
