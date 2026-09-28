import CoreGraphics
import Foundation

/// Plan §16 display identity: companions `CGDirectDisplayID` (same width,
/// convertible without loss). Assigned by the adapter from `NSScreen`
/// device descriptions — never invented in Core.
public struct DisplayID: Hashable, Sendable, Equatable {
    public let rawValue: UInt32

    /// `CGDirectDisplayID` is `UInt32`, so one init covers literals and IDs.
    public init(_ rawValue: CGDirectDisplayID) {
        self.rawValue = rawValue
    }
}

/// Plan §16 per-display state, in Cocoa coordinates (matching
/// `NSScreen.frame`). Each display points at a workspace and owns an
/// independent viewport over it — two displays may share one workspace's
/// columns while scrolled differently.
public struct DisplayState: Equatable, Sendable {
    public let id: DisplayID
    public var frame: CGRect
    public var workspace: WorkspaceID
    public var viewport: Viewport

    public init(id: DisplayID, frame: CGRect, workspace: WorkspaceID, viewport: Viewport) {
        self.id = id
        self.frame = frame
        self.workspace = workspace
        self.viewport = viewport
    }
}
