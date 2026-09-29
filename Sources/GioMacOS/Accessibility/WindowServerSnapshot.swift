import CoreGraphics
import Foundation
import GioCore

/// FI-05: what the WindowServer actually draws. PA-04: on-screen windows
/// only (never every window of every Space), since only visible targets are checked. `CGWindowListCopyWindowInfo`
/// is public and returns owner pid, layer and bounds without Screen
/// Recording; window names are a separate key that Gio never reads.
public func windowServerWindows(displayHeight: CGFloat) -> [ServerWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return parseWindowServerEntries(raw, displayHeight: displayHeight)
}

/// Layer-0 (normal) windows only, bounds converted from CG global
/// (top-left) to Cocoa. Malformed entries are dropped.
func parseWindowServerEntries(_ entries: [[String: Any]], displayHeight: CGFloat) -> [ServerWindow] {
    entries.compactMap { entry in
        guard let pid = entry[kCGWindowOwnerPID as String] as? Int,
              let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else {
            return nil
        }
        return ServerWindow(
            pid: pid_t(pid), bounds: cocoaFrame(fromWindowServer: bounds, displayHeight: displayHeight)
        )
    }
}

/// SM-02: every layer-0 window of `pids` with its `CGWindowID` (the same id
/// as `SCWindow.windowID`) and Cocoa bounds. Off-screen and other-Space
/// windows are included so parked windows can be matched too. Public API,
/// no Screen Recording needed; titles are never read.
public func windowServerSnapshotCandidates(pids: Set<pid_t>, displayHeight: CGFloat) -> [SnapshotCandidate] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return parseSnapshotCandidates(raw, pids: pids, displayHeight: displayHeight)
}

func parseSnapshotCandidates(
    _ entries: [[String: Any]], pids: Set<pid_t>, displayHeight: CGFloat
) -> [SnapshotCandidate] {
    entries.compactMap { entry in
        guard let pid = entry[kCGWindowOwnerPID as String] as? Int, pids.contains(pid_t(pid)),
              let number = entry[kCGWindowNumber as String] as? Int,
              let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else {
            return nil
        }
        return SnapshotCandidate(
            windowID: UInt32(truncatingIfNeeded: number), pid: pid_t(pid),
            frame: cocoaFrame(fromWindowServer: bounds, displayHeight: displayHeight)
        )
    }
}
