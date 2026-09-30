import ApplicationServices
import CoreGraphics
import Foundation
import GioCore

// Native zoom (the double-click on the title bar) through Accessibility.
//
// `kAXZoomButtonAttribute` returns the window's green button. On current macOS
// that button has subrole `AXFullScreenButton`: `AXPress` enters native full
// screen (its own Space, which Gio must never trigger) and the zoom itself is
// the separate `AXZoomWindow` action. Older windows expose a real
// `AXZoomButton` whose `AXPress` zooms.

/// The action that zooms the window, or nil when the button cannot zoom
/// without entering full screen.
func zoomActionName(subrole: String?, actions: [String]) -> String? {
    if actions.contains("AXZoomWindow") {
        return "AXZoomWindow"
    }
    if subrole == "AXFullScreenButton" {
        return nil
    }
    return actions.contains(kAXPressAction as String) ? kAXPressAction as String : nil
}

enum ZoomControl {
    case usable(button: AXUIElement, action: String)
    case unusable(String)
}

/// Reads the window's zoom button, its enabled state, subrole and actions.
/// Live-only; never reads titles.
func axZoomControl(of window: AXUIElement) -> ZoomControl {
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(window, kAXZoomButtonAttribute as CFString, &raw)
    guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        return .unusable("noZoomButton")
    }
    let button = raw as! AXUIElement
    var enabled: CFTypeRef?
    if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
       let flag = enabled as? Bool, !flag {
        return .unusable("disabled")
    }
    var actions: CFArray?
    _ = AXUIElementCopyActionNames(button, &actions)
    let names = (actions as? [String]) ?? []
    guard let action = zoomActionName(subrole: axString(of: button, attribute: kAXSubroleAttribute as String), actions: names)
    else {
        return .unusable("fullScreenButtonOnly")
    }
    return .usable(button: button, action: action)
}

/// Cocoa bounds from one WindowServer window entry; nil when it has none.
func parseWindowBounds(_ entry: [String: Any], displayHeight: CGFloat) -> CGRect? {
    guard let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    else {
        return nil
    }
    return cocoaFrame(fromWindowServer: bounds, displayHeight: displayHeight)
}

/// The Cocoa bounds the WindowServer currently draws for one window
/// (`CGWindowID`), or nil when it is not listed. Public API, no titles read.
public func windowServerBounds(windowID: UInt32, displayHeight: CGFloat) -> CGRect? {
    guard let raw = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]],
          let entry = raw.first
    else {
        return nil
    }
    return parseWindowBounds(entry, displayHeight: displayHeight)
}
