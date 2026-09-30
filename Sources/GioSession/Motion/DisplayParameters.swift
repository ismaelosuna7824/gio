import CoreGraphics
import Foundation
import GioCore

/// PA-03 / SM-04: screen parameters read on the main thread (AppKit) at start
/// and on every screen-parameter change, handed to the session queue behind
/// one lock: the refresh rates the motion paces to, and the screens the
/// snapshot capture needs. The session queue only reads this copy (when a
/// motion starts, when a capture runs) and never queries AppKit for it. The
/// three values are written together, so they share the lock.
public final class DisplayParameters: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes: [DisplayRefresh] = []
    private var screens: [SnapshotDisplay] = []
    private var primaryHeight: CGFloat = 1169

    public init() {}

    /// Main thread: publish a fresh reading.
    public func store(refreshes: [DisplayRefresh], captureScreens: [SnapshotDisplay], primaryHeight: CGFloat) {
        lock.withLock {
            self.refreshes = refreshes
            screens = captureScreens
            self.primaryHeight = primaryHeight
        }
    }

    /// The screens' refresh rates (empty until the first reading).
    public var displayRefreshes: [DisplayRefresh] {
        lock.withLock { refreshes }
    }

    /// Screens as the capture needs them, and the primary screen's height.
    public var captureScreens: ([SnapshotDisplay], CGFloat) {
        lock.withLock { (screens, primaryHeight) }
    }
}
