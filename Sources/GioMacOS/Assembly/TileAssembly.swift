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
///
/// Coordinates: `display` is Cocoa (e.g. `visibleFrame`); `displayHeight` is
/// the FULL display height for the AX flip. Discovery frames arrive AX-native
/// and are converted on ingest; layout and reconcile run in Cocoa.
public struct TileReflowReport: Equatable, Sendable {
    public var tiled: [WindowID]
    public var skippedMinimized: Int
    public var skippedUntileable: Int
    public var skippedDiscovery: Int
    public var skippedOffscreen: Int = 0
    public var reconcile: ReconcileReport
    public var displayInfo: String = ""

    public func describe() -> String {
        var lines = ["tiled=\(tiled.count)"]
        for id in tiled {
            lines.append("  pid=\(id.pid) element=\(id.elementID)")
        }
        lines.append("skipped minimized=\(skippedMinimized) untileable=\(skippedUntileable) discovery=\(skippedDiscovery) offscreen=\(skippedOffscreen)")
        lines.append(
            "reconcile applied=\(reconcile.applied.count) already=\(reconcile.alreadyCorrect.count) vanished=\(reconcile.vanished.count) failed=\(reconcile.failed.count) focusChanged=\(reconcile.focusChanged) focusFailed=\(reconcile.focusFailed)"
        )
        if let first = reconcile.firstFailure {
            lines.append("firstFailure=\(first)")
        }
        if !displayInfo.isEmpty {
            lines.append(displayInfo)
        }
        return lines.joined(separator: "\n")
    }
}

/// Live screen geometry readout: chosen viewport plus every NSScreen frame
/// and visibleFrame. When macOS clamps a requested frame, these numbers name
/// the real usable area — no guessing from stale assumptions.
public func describeDisplayGeometry(chosen viewport: CGRect) -> String {
    var lines = ["viewport=\(describeFrame(viewport))"]
    for (index, screen) in NSScreen.screens.enumerated() {
        lines.append(
            "screen\(index) frame=\(describeFrame(screen.frame)) visible=\(describeFrame(screen.visibleFrame))"
        )
    }
    return lines.joined(separator: "\n")
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

/// Split layout frames into visible and off-screen sets. macOS refuses
/// fully off-screen placements (learned live: writes outside the display
/// never stick), so only intersecting frames are attempted. The rest stay
/// managed state for future scrolled reflows — skipped, never failed.
public func splitVisibleFrames(
    _ frames: [WindowID: CGRect],
    in viewport: CGRect
) -> (visible: [WindowID: CGRect], skippedOffscreen: Int) {
    var visible: [WindowID: CGRect] = [:]
    var skipped = 0
    for (id, frame) in frames {
        if frame.intersects(viewport) {
            visible[id] = frame
        } else {
            skipped += 1
        }
    }
    return (visible, skipped)
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
    displayHeight: CGFloat,
    engine: ScrollableLayoutEngine = ScrollableLayoutEngine(),
    actuator: AXWindowActuator? = nil,
    registry: WindowRegistry = WindowRegistry()
) throws -> TileReflowReport {
    let flip = AXVerticalFlip(displayHeight: displayHeight)
    let actuator = actuator ?? AXWindowActuator(displayHeight: displayHeight)
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
            frame: flip.toCocoa(candidate.window.frame),
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
    let (visibleFrames, skippedOffscreen) = splitVisibleFrames(layout.frames, in: display)
    // Never steal focus: the desired focus is the currently focused window,
    // and only when it is among the tiled ones (it always is here).
    let reconciler = WindowReconciler(actuator: actuator)
    let reconcile = reconciler.reconcile(
        frames: visibleFrames,
        focused: focusedID,
        currentlyFocused: focusedID
    )
    return TileReflowReport(
        tiled: managed.map(\.id),
        skippedMinimized: skippedMinimized,
        skippedUntileable: skippedUntileable,
        skippedDiscovery: found.skipped,
        skippedOffscreen: skippedOffscreen,
        reconcile: reconcile,
        displayInfo: describeDisplayGeometry(chosen: display)
    )
}
