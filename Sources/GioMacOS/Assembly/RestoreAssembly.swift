import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore

public struct RestoreReport: Equatable, Sendable {
    public var scanned: Int
    public var restored: Int
    public var failed: Int
    public var firstFailure: String?

    public func describe() -> String {
        var line = "restore scanned=\(scanned) restored=\(restored) failed=\(failed)"
        if let firstFailure {
            line += "\nfirstFailure=\(firstFailure)"
        }
        return line
    }
}

/// Current displays as the restore planner wants them.
public func restoreDisplays() -> [RestoreDisplay] {
    snapshotDisplayList().map { RestoreDisplay(frame: $0.frame, visibleFrame: $0.visibleFrame) }
}

/// No-daemon recovery (`gio-poc restore`): enumerate every window, bring the
/// parked or off-screen ones back inside their display. Survives a killed
/// Gio (SIGKILL, Xcode Stop) that left windows parked. Minimized windows
/// are skipped; nothing on screen is touched.
public func runRestoreOffscreen() throws -> RestoreReport {
    let found = try discoverSystemWindows()
    let actuator = AXWindowActuator(displayHeight: NSScreen.main?.frame.height ?? 0)
    var ids: [WindowID] = []
    for (index, candidate) in (found.windows + found.floating).enumerated()
    where !candidate.window.isMinimized {
        let id = WindowID(pid: candidate.window.pid, elementID: UInt64(index + 1))
        actuator.register(
            elementID: id.elementID, pid: id.pid,
            element: candidate.element, appElement: candidate.appElement
        )
        ids.append(id)
    }
    let report = WindowReconciler(actuator: actuator)
        .restoreOffscreen(ids: ids, displays: restoreDisplays())
    return RestoreReport(
        scanned: ids.count, restored: report.applied.count,
        failed: report.failed.count, firstFailure: report.firstFailure
    )
}
