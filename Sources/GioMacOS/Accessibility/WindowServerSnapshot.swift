import CoreGraphics
import Foundation
import GioCore

/// FI-05: what the WindowServer actually draws. `CGWindowListCopyWindowInfo`
/// is public and returns owner pid, layer and bounds without Screen
/// Recording; window names are a separate key that Gio never reads.
public func windowServerWindows(displayHeight: CGFloat) -> [ServerWindow] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
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
