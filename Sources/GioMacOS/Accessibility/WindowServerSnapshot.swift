import CoreGraphics
import Foundation
import GioCore

/// FI-05: what the WindowServer actually draws. PA-04: on-screen windows
/// only (never every window of every Space), since only visible targets are checked. `CGWindowListCopyWindowInfo`
/// is public and returns owner pid, layer and bounds without Screen
/// Recording; window names are a separate key this list never reads.
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

/// Diagnostics for `render missing detail`: every layer-0 window of `pid`
/// in the complete list (other Spaces and off-screen included) with Cocoa
/// bounds and the WindowServer's on-screen flag. Public API, no titles read.
public func windowServerWindowStates(pid: pid_t, displayHeight: CGFloat) -> [ServerWindowState] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return raw.compactMap { entry in
        guard let owner = entry[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
              let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else {
            return nil
        }
        return ServerWindowState(
            bounds: cocoaFrame(fromWindowServer: bounds, displayHeight: displayHeight),
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }
}

/// SM-02: every layer-0 window of `pids` with its `CGWindowID` (the same id
/// as `SCWindow.windowID`) and Cocoa bounds. Parked and hidden-workspace
/// windows keep a sliver on screen (macOS refuses fully off-screen frames),
/// so the on-screen list holds every window a capture can ask for. PF-AD:
/// it used to list every window of every Space (`optionAll`, 157 entries
/// in the live session: 5 ms and 1.2 ms of Gio CPU per call, on every
/// capture run and every 30 ms paint check); on screen it is 16 entries,
/// 0.5 ms. Public API, no Screen Recording needed. SM-17: the window name
/// (`kCGWindowName`, listed only with Screen Recording) rides on the
/// candidate for the title tie-break and is never logged or stored.
public func windowServerSnapshotCandidates(pids: Set<pid_t>, displayHeight: CGFloat) -> [SnapshotCandidate] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
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
        let name = entry[kCGWindowName as String] as? String
        return SnapshotCandidate(
            windowID: UInt32(truncatingIfNeeded: number), pid: pid_t(pid),
            frame: cocoaFrame(fromWindowServer: bounds, displayHeight: displayHeight),
            title: name?.isEmpty == false ? name : nil
        )
    }
}

/// SM-20: the window numbers of the layer-0 on-screen windows of `pids`,
/// front to back (`kCGWindowListOptionOnScreenOnly` is documented as
/// "ordered from front to back"; `optionAll`, which lists the candidates,
/// documents no order). Parked windows keep a sliver on screen, so they are
/// listed; windows of other Spaces and minimized ones are not. Public API,
/// no titles read.
public func windowServerStacking(pids: Set<pid_t>) -> [UInt32] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return parseWindowServerStacking(raw, pids: pids)
}

func parseWindowServerStacking(_ entries: [[String: Any]], pids: Set<pid_t>) -> [UInt32] {
    entries.compactMap { entry in
        guard let pid = entry[kCGWindowOwnerPID as String] as? Int, pids.contains(pid_t(pid)),
              let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let number = entry[kCGWindowNumber as String] as? Int
        else {
            return nil
        }
        return UInt32(truncatingIfNeeded: number)
    }
}

/// SM-10: the `CGWindowID`s of every on-screen window of `pid`, whatever
/// its layer (Gio's ring, dim and overlay panels sit above layer 0). A
/// backdrop capture needs them in the shareable-content cache to exclude
/// them. Public API, no Screen Recording needed; titles are never read.
public func windowServerOnScreenWindowIDs(pid: pid_t) -> Set<UInt32> {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return parseWindowServerWindowIDs(raw, pid: pid)
}

func parseWindowServerWindowIDs(_ entries: [[String: Any]], pid: pid_t) -> Set<UInt32> {
    Set(entries.compactMap { entry in
        guard let owner = entry[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
              let number = entry[kCGWindowNumber as String] as? Int
        else {
            return nil
        }
        return UInt32(truncatingIfNeeded: number)
    })
}

/// Diagnostics: the size the WindowServer currently draws for one window
/// (`CGWindowID`), or nil when it is not listed. Public API, no titles read.
public func windowServerSize(windowID: UInt32) -> CGSize? {
    guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]],
          let entry = raw.first,
          let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    else {
        return nil
    }
    return bounds.size
}
