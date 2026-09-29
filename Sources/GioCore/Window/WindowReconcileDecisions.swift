import Foundation

/// What a config reload changes about one registered window.
public enum RuleReevaluation: Equatable, Sendable {
    /// Newly matching float rule: float with reason `rule`.
    case float(WindowID)
    /// Rule float that no longer matches: back to the grid.
    case tile(WindowID)
}

/// Re-run window rules over registered windows after a config reload.
/// Only rule-owned state moves: tiled windows a float rule now matches
/// become floating(`rule`); floating(`rule`) windows that stopped matching
/// return to tiled. Admission floats (`notResizable`, `dialog`,
/// `floatingSubrole`) and manual floats are never promoted or relabeled,
/// and fullscreen windows are left alone. Workspace assignment is NOT
/// re-applied: rules place windows only at arrival.
public func reevaluateRules(_ rules: [WindowRule], windows: [ManagedWindow]) -> [RuleReevaluation] {
    var changes: [RuleReevaluation] = []
    for window in windows {
        let wantsFloat = evaluateRules(rules, app: window.application).mode == .floating
        switch window.mode {
        case .tiled where wantsFloat:
            changes.append(.float(window.id))
        case .floating where window.floatReason == .rule && !wantsFloat:
            changes.append(.tile(window.id))
        default:
            break
        }
    }
    return changes
}

/// Fallback purge for a full rescan: registered windows of a pid whose
/// window list was read completely, yet absent from that scan, are gone.
/// Pids outside `scannedPIDs` (read failed, app busy or hidden) are never
/// touched, so an unreadable app cannot wipe state. Minimized windows count
/// as present when the scan returned them. IDs come back sorted.
public func vanishedWindowIDs(
    registered: [ManagedWindow],
    scannedPIDs: Set<pid_t>,
    present: Set<WindowID>
) -> [WindowID] {
    registered
        .filter { scannedPIDs.contains($0.pid) && !present.contains($0.id) }
        .map(\.id)
        .sorted()
}
