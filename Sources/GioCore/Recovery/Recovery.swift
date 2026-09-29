import Foundation

/// Plan §23 recovery input. `liveIDs` come from a fresh enumeration,
/// `terminatedPIDs` from process notifications (proof of death, unlike mere
/// absence), `displaysSeen` from a fresh display snapshot.
public struct RecoveryInput: Sendable {
    public var liveIDs: Set<WindowID>
    public var terminatedPIDs: Set<pid_t>
    public var displaysSeen: Set<DisplayID>
    public var permissionGranted: Bool
    public var snapshotComplete: Bool

    public init(
        liveIDs: Set<WindowID> = [],
        terminatedPIDs: Set<pid_t> = [],
        displaysSeen: Set<DisplayID> = [],
        permissionGranted: Bool = true,
        snapshotComplete: Bool = true
    ) {
        self.liveIDs = liveIDs
        self.terminatedPIDs = terminatedPIDs
        self.displaysSeen = displaysSeen
        self.permissionGranted = permissionGranted
        self.snapshotComplete = snapshotComplete
    }
}

public struct RecoveryReport: Equatable, Sendable {
    public var prunedStale: [WindowID]
    public var reapedProcesses: [pid_t]
    public var droppedDisplays: [DisplayID]
    public var permissionLost: Bool
    public var snapshotIncomplete: Bool
}

/// The mutable world recovery rewrites. Local-use struct (holds the
/// reference-type registry); the caller owns the actual session.
public struct RecoveryState {
    public var registry: WindowRegistry
    public var manager: WorkspaceManager
    public var displays: DisplayManager
}

/// Plan §23 pipeline: detect stale → remove → recalculate → reconcile (the
/// caller reconciles from the cleaned state). Rules:
///
/// - Terminated PIDs are reaped ALWAYS — a termination notification proves
///   death even when snapshots are incomplete or permission is lost.
/// - Stale pruning and display drops run ONLY with permission granted and a
///   complete snapshot. Otherwise the state freezes: an empty or partial
///   enumeration must never read as "everything died".
/// - Workspaces never lose columns except through pruned windows; displays
///   never touch workspaces.
@discardableResult
public func recover(state: inout RecoveryState, input: RecoveryInput) -> RecoveryReport {
    var report = RecoveryReport(
        prunedStale: [],
        reapedProcesses: [],
        droppedDisplays: [],
        permissionLost: !input.permissionGranted,
        snapshotIncomplete: input.permissionGranted && !input.snapshotComplete
    )
    let reaped = input.terminatedPIDs.sorted().flatMap { pid in
        state.registry.removeWindows(ofPID: pid).map(\.id)
    }
    if !reaped.isEmpty {
        report.reapedProcesses = input.terminatedPIDs.sorted()
        stripFromWorkspaces(Set(reaped), state: &state)
    }
    guard input.permissionGranted, input.snapshotComplete else {
        return report
    }
    let pruned = state.registry.removeStale(keeping: input.liveIDs).map(\.id)
    if !pruned.isEmpty {
        report.prunedStale = pruned.sorted()
        stripFromWorkspaces(Set(pruned), state: &state)
    }
    let known = Set(state.displays.allDisplays().map(\.id))
    let dropped = known.subtracting(input.displaysSeen).sorted { $0.rawValue < $1.rawValue }
    for id in dropped {
        state.displays.disconnect(id)
    }
    report.droppedDisplays = dropped
    return report
}

private func stripFromWorkspaces(_ ids: Set<WindowID>, state: inout RecoveryState) {
    for candidate in state.manager.allWorkspaces {
        var workspace = candidate
        let before = workspace
        workspace.stripWindows(ids)
        if workspace != before {
            state.manager.update(workspace)
        }
    }
}
