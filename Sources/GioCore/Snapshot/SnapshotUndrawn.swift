import CoreGraphics
import Foundation

// SM-31: a window macOS no longer draws must never have its cached image
// flown: the layer would show it for the whole flight and it would vanish
// at the hand-off, on every motion. Such windows lose their images and stay
// out of every flight (`planSnapshotFlight(undrawn:)`) until a capture
// matches them again.

/// Why a registered window's images were dropped.
public enum SnapshotEvictReason: String, Equatable, Sendable {
    /// The reconciler found its AX element invalid (`ReconcileReport.vanished`).
    case vanished
    /// A capture found no WindowServer window for it while it sits on a
    /// display with nothing of its app drawn there (`snapshotUndrawnWindows`).
    case undrawn
}

/// `snapshot evict id=P:E reason=vanished|undrawn` (debug; ids only, never a title).
public func snapshotEvictLine(id: WindowID, reason: SnapshotEvictReason) -> String {
    "snapshot evict id=\(id.pid):\(id.elementID) reason=\(reason.rawValue)"
}

/// The windows of a capture's `misses` that macOS does not draw. Two
/// independent proofs: the capture found no WindowServer window for it
/// (`unmatched`; `ambiguous`, `blank`, `failed` and `over-budget` prove
/// nothing), and FI-08's render check on the on-screen list (`server`,
/// layer 0) at its current frame (`frames`) reads it missing: at least half
/// of it is on a display (`viewports`) and no on-screen window of its app
/// covers 30 % of it. Everything FI-08 calls unknown keeps its image: a peek
/// or edge column or parking sliver (`offscreenTarget`), an ambiguous match,
/// an app drawing something over the frame (`overlapsOther`). A window drawn
/// elsewhere is matched, not missing. An empty list (unavailable) proves
/// nothing, nor does a window without a frame.
public func snapshotUndrawnWindows(
    misses: [WindowID: SnapshotMiss], frames: [WindowID: CGRect], server: [ServerWindow], viewports: [CGRect]
) -> Set<WindowID> {
    guard !server.isEmpty else {
        return []
    }
    let candidates = frames.filter { misses[$0.key] == .unmatched }
    guard !candidates.isEmpty else {
        return []
    }
    let verdict = evaluateRender(axFrames: candidates, server: server, targets: candidates, viewports: viewports)
    return Set(verdict.mismatches.filter { $0.ws == nil }.map(\.id))
}
