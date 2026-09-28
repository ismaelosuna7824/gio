import AppKit
import CoreGraphics
import Foundation
import GioCore

/// Live display snapshot for the manager: Cocoa frame plus visible frame,
/// keyed by the plan's `DisplayID`. Read fresh on every topology event —
/// never cached across connect/disconnect/resolution changes. Live-only
/// (needs real screens); event wiring lands with the daemon assembly.
public struct DisplaySnapshot: Equatable, Sendable {
    public let id: DisplayID
    public let frame: CGRect
    public let visibleFrame: CGRect
}

public func snapshotDisplayList() -> [DisplaySnapshot] {
    var result: [DisplaySnapshot] = []
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else {
            continue
        }
        result.append(DisplaySnapshot(
            id: DisplayID(CGDirectDisplayID(number.uint32Value)),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        ))
    }
    return result.sorted { $0.id.rawValue < $1.id.rawValue }
}
