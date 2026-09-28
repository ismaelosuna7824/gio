import CoreGraphics
import Foundation

/// Plan §16 display manager: pure topology transitions. Connect adds or
/// refreshes a display (frame changes re-fit its viewport width and clamp
/// the offset); disconnect drops only that display's record — workspaces
/// themselves are untouched, so unplugging B never corrupts A. Detection of
/// the underlying events (connect/disconnect/resolution/scale) lives in the
/// adapter (`GioMacOS/Displays`); this type decides state, never I/O.
public struct DisplayManager: Equatable, Sendable {
    private var displays: [DisplayID: DisplayState]

    public init() {
        self.displays = [:]
    }

    public func display(_ id: DisplayID) -> DisplayState? {
        displays[id]
    }

    public func allDisplays() -> [DisplayState] {
        displays.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { displays[$0] }
    }

    /// New display, or refreshed frame for a known one (resolution/scale
    /// change). A fresh display starts on the given workspace at offset
    /// zero; a known one keeps its workspace and viewport offset, re-fit to
    /// the new width.
    @discardableResult
    public mutating func connect(
        _ id: DisplayID,
        frame: CGRect,
        workspace: WorkspaceID
    ) -> DisplayState {
        if var known = displays[id] {
            known.frame = frame
            // Keep the scrolled offset; re-fit width to the new resolution.
            // Real content bounds clamp it on the next layout pass.
            known.viewport = Viewport(
                offset: known.viewport.offset, width: frame.width
            ).clamped(contentWidth: .greatestFiniteMagnitude)
            displays[id] = known
            return known
        }
        let state = DisplayState(
            id: id,
            frame: frame,
            workspace: workspace,
            viewport: Viewport(offset: 0, width: frame.width)
        )
        displays[id] = state
        return state
    }

    /// Drop one display's record, returning it. Workspaces are not touched.
    @discardableResult
    public mutating func disconnect(_ id: DisplayID) -> DisplayState? {
        displays.removeValue(forKey: id)
    }

    /// Point a display at another workspace, keeping its viewport offset
    /// (re-clamped later against real content by the layout pass).
    @discardableResult
    public mutating func assign(_ id: DisplayID, workspace: WorkspaceID) -> Bool {
        guard var state = displays[id] else {
            return false
        }
        state.workspace = workspace
        displays[id] = state
        return true
    }

    /// Update a display's viewport (e.g. after a scrolled reflow).
    public mutating func updateViewport(_ viewport: Viewport, for id: DisplayID) {
        guard var state = displays[id] else {
            return
        }
        state.viewport = viewport
        displays[id] = state
    }
}
