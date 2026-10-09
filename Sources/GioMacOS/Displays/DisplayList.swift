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
    /// MM-04: for the `display ...` log line only.
    public let scale: CGFloat
    /// Maximum refresh rate in Hz (0 when unknown); log only.
    public let refreshRate: Int

    public init(id: DisplayID, frame: CGRect, visibleFrame: CGRect, scale: CGFloat = 1, refreshRate: Int = 0) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.refreshRate = refreshRate
    }
}

/// Every screen, in position order (MM-01: left to right, then top to
/// bottom; `displaysByPosition`), never by raw display ID.
public func snapshotDisplayList() -> [DisplaySnapshot] {
    var result: [DisplayID: DisplaySnapshot] = [:]
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else {
            continue
        }
        let id = DisplayID(CGDirectDisplayID(number.uint32Value))
        result[id] = DisplaySnapshot(
            id: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
            scale: screen.backingScaleFactor, refreshRate: screen.maximumFramesPerSecond
        )
    }
    return displaysByPosition(result.mapValues(\.frame)).compactMap { result[$0] }
}

/// MM-01: the primary screen (`primaryDisplayIndex`: the one at the Cocoa
/// origin), whose height is the global AX/WindowServer flip reference.
/// Never `NSScreen.main`, which follows the key window.
public func primaryScreen() -> NSScreen? {
    let screens = NSScreen.screens
    return primaryDisplayIndex(screens.map(\.frame)).map { screens[$0] }
}

/// PA-03: each screen's frame and refresh rate. AppKit state: call on the
/// main thread and publish the result to the session.
public func snapshotDisplayRefreshes() -> [DisplayRefresh] {
    NSScreen.screens.map {
        DisplayRefresh(frame: $0.frame, framesPerSecond: $0.maximumFramesPerSecond)
    }
}
