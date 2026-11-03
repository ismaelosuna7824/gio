import Foundation

/// WC-19: which floating windows need their window-server level raised (so
/// they stay above the tiled strip, like niri's floating layer) or put back
/// after a pass. Pure: the adapter decides whether the level can actually be
/// set; this only says what changed since the last time.
public struct FloatingLevelChanges: Equatable, Sendable {
    public var raise: Set<WindowID>
    public var restore: Set<WindowID>

    public init(raise: Set<WindowID> = [], restore: Set<WindowID> = []) {
        self.raise = raise
        self.restore = restore
    }

    public var isEmpty: Bool { raise.isEmpty && restore.isEmpty }
}

/// `raised` are the windows that hold the raised level now; `floating` every
/// floating window of the session. A window that stopped floating gets its
/// level back before it is written into the strip again.
public func floatingLevelChanges(raised: Set<WindowID>, floating: Set<WindowID>) -> FloatingLevelChanges {
    FloatingLevelChanges(raise: floating.subtracting(raised), restore: raised.subtracting(floating))
}
