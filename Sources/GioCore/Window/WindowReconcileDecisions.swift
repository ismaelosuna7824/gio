import Foundation

/// What a config reload changes about one registered window.
public enum RuleReevaluation: Equatable, Sendable {
    /// Newly matching float rule: float with reason `rule`.
    case float(WindowID)
    /// Rule float that no longer matches: back to the grid.
    case tile(WindowID)
    /// WR-05: the matching rule's width limits changed (nil: none now).
    case widthLimits(WindowID, ColumnWidthLimits?)
}

/// Re-run window rules over registered windows after a config reload.
/// Only rule-owned state moves: tiled windows a float rule now matches
/// become floating(`rule`); floating(`rule`) windows that stopped matching
/// return to tiled. Admission floats (`notResizable`, `dialog`,
/// `floatingSubrole`) and manual floats are never promoted or relabeled,
/// and fullscreen windows are left alone. Workspace assignment, column
/// width, maximized, display and focus are NOT re-applied: rules place
/// windows only at arrival. WR-01/WR-05: title rules match the current
/// title, and `min-width` / `max-width` (a constraint, not a placement)
/// follow the new rules.
public func reevaluateRules(_ rules: [WindowRule], windows: [ManagedWindow]) -> [RuleReevaluation] {
    var changes: [RuleReevaluation] = []
    for window in windows {
        let outcome = evaluateRules(rules, app: window.application, bundleID: window.bundleID, title: window.title)
        let wantsFloat = outcome.mode == .floating
        if outcome.widthLimits != window.widthLimits {
            changes.append(.widthLimits(window.id, outcome.widthLimits))
        }
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

/// FI-15: the absence purge split by the window server's word.
public struct VanishConfirmation: Equatable, Sendable {
    /// Gone: purge them. Sorted.
    public var purge: [WindowID]
    /// The window server still lists their recorded number. Sorted.
    public var kept: [WindowID]

    public init(purge: [WindowID], kept: [WindowID]) {
        self.purge = purge
        self.kept = kept
    }
}

/// FI-15: absence from a complete scan is confirmed by the window server
/// (rule 10). While the screen locks, the apps' Accessibility lists hold no
/// window although every window is still there: a candidate whose recorded
/// window number the window server still lists is kept. A destroyed notice
/// is the window server's own proof, and a window without a recorded number
/// cannot be asked about: both are purged as before.
public func confirmedVanished(
    candidates: [WindowID], numbers: [WindowID: UInt32], liveNumbers: Set<UInt32>, destroyed: Set<WindowID>
) -> VanishConfirmation {
    var result = VanishConfirmation(purge: [], kept: [])
    for id in candidates.sorted() {
        if !destroyed.contains(id), let number = numbers[id], liveNumbers.contains(number) {
            result.kept.append(id)
        } else {
            result.purge.append(id)
        }
    }
    return result
}

/// FI-15: the window server needs asking only when a recorded number could
/// keep a candidate (one query per purge batch, none for an empty one).
public func vanishNeedsWindowServer(
    candidates: [WindowID], numbers: [WindowID: UInt32], destroyed: Set<WindowID>
) -> Bool {
    candidates.contains { numbers[$0] != nil && !destroyed.contains($0) }
}
