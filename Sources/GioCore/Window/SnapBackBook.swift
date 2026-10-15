import Foundation

/// FI-10: what one non-echo frame change of a managed window means for the
/// fight between Gio and the app.
public enum SnapBackVerdict: Equatable, Sendable {
    /// Not a snap-back: the user is dragging, or Gio did not write the
    /// window shortly before.
    case ignored
    /// A snap-back, the n-th within `SnapBackBook.span`.
    case counted(Int)
    /// The cap: the window yields to its app (the count starts over).
    case yield(Int)
}

/// FI-10: counts the times an app restored its own frame right after Gio
/// wrote the window (an installer re-centring itself, an app re-showing a
/// window Gio parked, one refusing a position). Without a cap each restore
/// is written back by the next reflow, every ~0.3 s, forever.
///
/// A non-echo frame change counts when it comes at most `window` (1.5 s)
/// after Gio's last write to that window (a debounced write-back plus the
/// app's reaction) and no mouse button is down (a user drag never counts).
/// `cap` (3) counts within `span` (10 s) make the window yield: the caller
/// floats it as `FloatReason.appControlled` and Gio stops writing it. The
/// count starts over at the yield and when the window is forgotten (purge,
/// re-registration). Pure value type; time is injected.
public struct SnapBackBook: Sendable {
    public static let window: TimeInterval = 1.5
    public static let span: TimeInterval = 10
    public static let cap = 3

    private var snaps: [WindowID: [TimeInterval]] = [:]

    public init() {}

    /// One non-echo frame change of `id` at `time`; `lastWrite` is when
    /// Gio last wrote it (nil: never).
    public mutating func note(
        _ id: WindowID, at time: TimeInterval, lastWrite: TimeInterval?, dragging: Bool
    ) -> SnapBackVerdict {
        guard !dragging, let lastWrite, time - lastWrite <= Self.window else {
            return .ignored
        }
        var recent = (snaps[id] ?? []).filter { time - $0 <= Self.span }
        recent.append(time)
        guard recent.count >= Self.cap else {
            snaps[id] = recent
            return .counted(recent.count)
        }
        snaps.removeValue(forKey: id)
        return .yield(recent.count)
    }

    public mutating func forget(_ id: WindowID) {
        snaps.removeValue(forKey: id)
    }
}
