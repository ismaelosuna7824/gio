import CoreGraphics
import Foundation
import GioCore

/// PA-03 / SM-04: screen parameters read on the main thread (AppKit) at start
/// and on every screen-parameter change, handed to the session queue behind
/// one lock: the refresh rates the motion paces to, and the screens the
/// snapshot capture needs. The session queue only reads this copy (when a
/// motion starts, when a capture runs, PA-15c: every flip of a WindowServer
/// query) and never queries AppKit for it. The three values are written
/// together, so they share the lock.
public final class DisplayParameters: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes: [DisplayRefresh] = []
    private var screens: [SnapshotDisplay] = []
    private var primary: CGFloat?

    public init() {}

    /// Main thread: publish a fresh reading.
    public func store(refreshes: [DisplayRefresh], captureScreens: [SnapshotDisplay], primaryHeight: CGFloat) {
        lock.withLock {
            self.refreshes = refreshes
            screens = captureScreens
            primary = primaryHeight
        }
    }

    /// The screens' refresh rates (empty until the first reading).
    public var displayRefreshes: [DisplayRefresh] {
        lock.withLock { refreshes }
    }

    /// Screens as the capture needs them, and the primary screen's height.
    public var captureScreens: ([SnapshotDisplay], CGFloat) {
        lock.withLock { (screens, primary ?? 1169) }
    }

    /// The primary screen's height (the AX/WindowServer flip), nil until
    /// the first reading.
    public var primaryHeight: CGFloat? {
        lock.withLock { primary }
    }
}
