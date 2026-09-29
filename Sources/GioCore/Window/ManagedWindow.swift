import CoreGraphics
import Foundation

/// Plan §7 window mode. Floating windows keep position/size outside the
/// layout; fullscreen preserves prior state for restoration.
public enum WindowMode: String, Equatable, Sendable {
    case tiled
    case floating
    case fullscreen
}

/// Plan §17 fullscreen memory: what to restore on exit. Captured on entry
/// because the record's own frame is overwritten by the fullscreen frame.
public struct FullscreenRecord: Equatable, Sendable {
    public let id: WindowID
    public let previousFrame: CGRect
    public let previousMode: WindowMode

    public init(id: WindowID, previousFrame: CGRect, previousMode: WindowMode) {
        self.id = id
        self.previousFrame = previousFrame
        self.previousMode = previousMode
    }
}

/// A window tracked by the registry. `title` is `""` when Accessibility
/// reports no title — unknown titles never block management. `frame` is the
/// last known logical frame; only the reconciler (Phase 8) writes physical
/// frames from it. Floating windows keep their frame untouched by layout;
/// fullscreen overwrites it and restores from a `FullscreenRecord` on exit.
public struct ManagedWindow: Equatable, Sendable {
    public let id: WindowID
    public let pid: pid_t
    public let application: String
    public var title: String
    public var frame: CGRect
    public var mode: WindowMode
    /// Why the window floats; nil unless `mode == .floating`.
    public var floatReason: FloatReason?
    /// Minimized windows stay registered (and keep their column) but sit out
    /// of the layout until they are deminimized.
    public var isMinimized: Bool

    public init(
        id: WindowID,
        pid: pid_t,
        application: String,
        title: String,
        frame: CGRect,
        mode: WindowMode,
        floatReason: FloatReason? = nil,
        isMinimized: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.application = application
        self.title = title
        self.frame = frame
        self.mode = mode
        self.floatReason = floatReason
        self.isMinimized = isMinimized
    }
}
