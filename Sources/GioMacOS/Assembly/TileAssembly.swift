import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore

/// Plan §35 assembly: discovery → IDs → registry → workspace → layout →
/// reconciler, runnable as `gio-poc tile`. One-shot by design: each process
/// run re-enumerates, so `elementID`s come from enumeration order. A future
/// daemon (RW-10+) will keep the counter across reflows instead.
///
/// Scope: main display only (multi-monitor is RW-11), one column per window
/// (the §35 strip), minimized and untileable windows skipped with counts,
/// focus never stolen (the desired focus is the currently focused window
/// when it is among the tiled ones, else nil).
public struct TileReflowReport: Equatable, Sendable {
    public var tiled: [WindowID]
    public var skippedMinimized: Int
    public var skippedUntileable: Int
    public var skippedDiscovery: Int
    public var reconcile: ReconcileReport

    public func describe() -> String {
        var lines = ["tiled=\(tiled.count)"]
        for id in tiled {
            lines.append("  pid=\(id.pid) element=\(id.elementID)")
        }
        lines.append("skipped minimized=\(skippedMinimized) untileable=\(skippedUntileable) discovery=\(skippedDiscovery)")
        lines.append(
            "reconcile applied=\(reconcile.applied.count) already=\(reconcile.alreadyCorrect.count) vanished=\(reconcile.vanished.count) failed=\(reconcile.failed.count) focusChanged=\(reconcile.focusChanged) focusFailed=\(reconcile.focusFailed)"
        )
        return lines.joined(separator: "\n")
    }
}

/// Drop minimized windows before tiling. Pure; the AX tileability probe
/// (`axIsTileable`) runs separately because it needs live elements.
public func selectTileCandidates(_ found: [DiscoveredSystemWindow]) -> (
    candidates: [DiscoveredSystemWindow], skippedMinimized: Int
) {
    var candidates: [DiscoveredSystemWindow] = []
    var skipped = 0
    for window in found {
        if window.window.isMinimized {
            skipped += 1
        } else {
            candidates.append(window)
        }
    }
    return (candidates, skipped)
}

/// One column per window, focused on the first, viewport at zero.
public func makeTileWorkspace(windows: [ManagedWindow]) -> Workspace {
    let columns = windows.enumerated().map { offset, window in
        Column(id: ColumnID(UInt64(offset + 1)), width: 0, windows: [window.id])
    }
    return Workspace(
        id: WorkspaceID(1),
        columns: columns,
        focusedColumn: 0,
        focusedWindow: windows.first?.id,
        viewportOffset: 0
    )
}

public func runTileReflow(
    display: CGRect,
    engine: ScrollableLayoutEngine = ScrollableLayoutEngine(),
    actuator: AXWindowActuator = AXWindowActuator(),
    registry: WindowRegistry = WindowRegistry()
) throws -> TileReflowReport {
    let found = try discoverSystemWindows()
    let (candidates, skippedMinimized) = selectTileCandidates(found.windows)
    var managed: [ManagedWindow] = []
    var skippedUntileable = 0
    var focusedID: WindowID?
    for (index, candidate) in candidates.enumerated() {
        guard axIsTileable(candidate.element) else {
            skippedUntileable += 1
            continue
        }
        let id = WindowID(pid: candidate.window.pid, elementID: UInt64(index + 1))
        actuator.register(
            elementID: id.elementID,
            pid: id.pid,
            element: candidate.element,
            appElement: candidate.appElement
        )
        let window = ManagedWindow(
            id: id,
            pid: candidate.window.pid,
            application: candidate.window.appName,
            title: candidate.window.title ?? "",
            frame: candidate.window.frame,
            mode: .tiled
        )
        try registry.register(window)
        managed.append(window)
        if candidate.window.isFocused {
            focusedID = id
        }
    }
    let workspace = makeTileWorkspace(windows: managed)
    let layout = try engine.calculate(workspace: workspace, viewport: display)
    // Never steal focus: the desired focus is the currently focused window,
    // and only when it is among the tiled ones (it always is here).
    let reconciler = WindowReconciler(actuator: actuator)
    let reconcile = reconciler.reconcile(
        frames: layout.frames,
        focused: focusedID,
        currentlyFocused: focusedID
    )
    return TileReflowReport(
        tiled: managed.map(\.id),
        skippedMinimized: skippedMinimized,
        skippedUntileable: skippedUntileable,
        skippedDiscovery: found.skipped,
        reconcile: reconcile
    )
}
