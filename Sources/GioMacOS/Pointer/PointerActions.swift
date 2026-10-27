import AppKit
import CoreGraphics
import Foundation
import GioCore

/// Cursor warp for `mouse-follows-focus`. Takes a Cocoa point (the frames'
/// space) and converts it against the primary display, the origin CoreGraphics
/// warps in. The cursor stays associated with the mouse so it keeps moving.
public func warpCursor(toCocoa point: CGPoint) {
    guard let primary = NSScreen.screens.first else {
        return
    }
    let target = globalDisplayPoint(fromCocoa: point, primaryHeight: primary.frame.height)
    CGWarpMouseCursorPosition(target)
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// Owner pid of the frontmost real window at a Cocoa point, or nil when the
/// topmost thing there is not an ordinary window (menu bar, Dock, popups,
/// floating panels, the cursor layer). Used by `focus-follows-mouse` so a
/// popup or Gio's own panel over a managed window blocks the hover.
public func topWindowOwnerPID(atCocoa point: CGPoint) -> pid_t? {
    guard let primary = NSScreen.screens.first,
          let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else {
        return nil
    }
    let global = globalDisplayPoint(fromCocoa: point, primaryHeight: primary.frame.height)
    for entry in info {
        // Front-to-back. Skip invisible windows and the WindowServer cursor.
        if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
            continue
        }
        if (entry[kCGWindowOwnerName as String] as? String) == "Window Server" {
            continue
        }
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.contains(global)
        else {
            continue
        }
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              let pid = entry[kCGWindowOwnerPID as String] as? Int32
        else {
            return nil
        }
        return pid
    }
    return nil
}

/// What a click at a Cocoa point landed on (`clickTarget` over the on-screen
/// windows, front to back, in CoreGraphics global space): WC-13 the Dock or
/// the menu bar, WC-16 the app whose window it hit. Gio's own panels are
/// skipped there. One WindowServer query; nothing known when it fails.
public func clickTarget(atCocoa point: CGPoint, ownPID: pid_t) -> ClickTarget {
    guard let primary = NSScreen.screens.first,
          let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else {
        return ClickTarget(onSystemUI: false, ownerPID: nil)
    }
    let windows: [PointWindow] = info.compactMap { entry in
        if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
            return nil
        }
        if (entry[kCGWindowOwnerName as String] as? String) == "Window Server" {
            return nil
        }
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let layer = entry[kCGWindowLayer as String] as? Int,
              let pid = entry[kCGWindowOwnerPID as String] as? Int32
        else {
            return nil
        }
        return PointWindow(pid: pid, layer: layer, bounds: rect)
    }
    let global = globalDisplayPoint(fromCocoa: point, primaryHeight: primary.frame.height)
    return clickTarget(at: global, frontToBack: windows, ownPID: ownPID)
}
