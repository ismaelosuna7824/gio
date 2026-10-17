/// PF-AQ: why an instant pass asks the snapshot cache for a settle run.
public enum SettleCaptureReason: String, Equatable, Sendable {
    /// The pass applied, parked, failed, vanished or deferred a window.
    case wrote
    /// The pass ends an AX motion, which already moved the windows.
    case motion
    /// An instant placement (startup, permission, mouse, displays).
    case placement
    /// The shown workspaces changed: strips and adjacent coverage move.
    case shown
}

/// PF-AQ: a pass that changes nothing (every window already correct, e.g.
/// one per Chrome omnibox keystroke) starts no capture run; the dirty
/// signals (typing, focus, new window) keep their own targeted runs.
/// A snapshot flight schedules its own run when it settles. Session queue only.
public struct SettleCaptureGate: Sendable {
    private var shown: Set<WorkspaceID>?
    private var motionPending = false

    public init() {}

    /// An AX motion moves the windows; the pass that ends it captures.
    public mutating func noteMotion() {
        motionPending = true
    }

    /// A snapshot flight's settle schedules the run itself.
    public mutating func noteFlight(shown: Set<WorkspaceID>) {
        motionPending = false
        self.shown = shown
    }

    /// The reason this instant pass needs a settle run, nil for a no-op pass.
    public mutating func decide(
        report: ReconcileReport, placement: InstantPlacementDecision, shown: Set<WorkspaceID>
    ) -> SettleCaptureReason? {
        let shownChanged = self.shown != shown
        let afterMotion = motionPending
        self.shown = shown
        motionPending = false
        let wrote = !report.applied.isEmpty || !report.parked.isEmpty || !report.failed.isEmpty
            || !report.vanished.isEmpty || !report.deferred.isEmpty
        if wrote {
            return .wrote
        }
        if afterMotion {
            return .motion
        }
        if case .instant(_?) = placement {
            return .placement
        }
        return shownChanged ? .shown : nil
    }
}

public let settleCaptureSkippedLogLine = "snapshot settle skipped reason=noop"
