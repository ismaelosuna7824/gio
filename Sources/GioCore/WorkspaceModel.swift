/// Stable identifiers supplied by the caller; the model never interprets their contents.
public struct DisplayID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}

public struct WindowID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}

public struct WorkspaceID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}

public enum WorkspaceModelError: Error, Equatable {
    case unknownDisplay(DisplayID)
    case duplicateDisplay(DisplayID)
    case unknownWorkspace(DisplayID, WorkspaceID)
    case duplicateWorkspace(DisplayID, WorkspaceID)
    case unknownWindow(WindowID)
    case duplicateWindow(WindowID)
}

/// A requested visibility change, not a platform window operation.
public enum WindowTransition: Equatable, Sendable {
    case hide(WindowID)
    case show(WindowID)
}

/// Pure membership and visibility planner. Callers execute transitions and own recovery
/// if a platform operation fails; this type does not move or inspect windows.
public struct WorkspaceModel {
    private struct Display {
        var workspaces: Set<WorkspaceID>
        var active: WorkspaceID
    }

    private struct Membership {
        var display: DisplayID
        var workspace: WorkspaceID
    }

    private var displays: [DisplayID: Display] = [:]
    private var windows: [WindowID: Membership] = [:]

    public init() {}

    public func activeWorkspace(on display: DisplayID) throws -> WorkspaceID {
        guard let state = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        return state.active
    }

    public func membership(of window: WindowID) throws -> (display: DisplayID, workspace: WorkspaceID) {
        guard let assignment = windows[window] else { throw WorkspaceModelError.unknownWindow(window) }
        return (assignment.display, assignment.workspace)
    }

    public mutating func addDisplay(_ display: DisplayID, initialWorkspace: WorkspaceID) throws {
        guard displays[display] == nil else { throw WorkspaceModelError.duplicateDisplay(display) }
        displays[display] = Display(workspaces: [initialWorkspace], active: initialWorkspace)
    }

    public mutating func addWorkspace(_ workspace: WorkspaceID, on display: DisplayID) throws {
        guard var state = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        guard state.workspaces.insert(workspace).inserted else {
            throw WorkspaceModelError.duplicateWorkspace(display, workspace)
        }
        displays[display] = state
    }

    /// Unregistering a display releases all its windows. Previously hidden windows
    /// are explicitly shown so the caller can restore them before losing ownership.
    @discardableResult
    public mutating func removeDisplay(_ display: DisplayID) throws -> [WindowTransition] {
        guard let state = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        let owned = windows.keys.filter { windows[$0]?.display == display }.sorted { $0.rawValue < $1.rawValue }
        let transitions = owned.compactMap { window -> WindowTransition? in
            windows[window]?.workspace == state.active ? nil : .show(window)
        }
        for window in owned { windows.removeValue(forKey: window) }
        displays.removeValue(forKey: display)
        return transitions
    }

    @discardableResult
    public mutating func assign(_ window: WindowID, to workspace: WorkspaceID, on display: DisplayID) throws -> [WindowTransition] {
        try validate(workspace, on: display)
        guard windows[window] == nil else { throw WorkspaceModelError.duplicateWindow(window) }
        windows[window] = Membership(display: display, workspace: workspace)
        return displays[display]!.active == workspace ? [] : [.hide(window)]
    }

    @discardableResult
    public mutating func reassign(_ window: WindowID, to workspace: WorkspaceID, on display: DisplayID) throws -> [WindowTransition] {
        try validate(workspace, on: display)
        guard let old = windows[window] else { throw WorkspaceModelError.unknownWindow(window) }
        let wasVisible = displays[old.display]!.active == old.workspace
        let isVisible = displays[display]!.active == workspace
        windows[window] = Membership(display: display, workspace: workspace)
        if wasVisible == isVisible { return [] }
        return [isVisible ? .show(window) : .hide(window)]
    }

    @discardableResult
    public mutating func removeWindow(_ window: WindowID) throws -> [WindowTransition] {
        guard let old = windows.removeValue(forKey: window) else { throw WorkspaceModelError.unknownWindow(window) }
        return displays[old.display]!.active == old.workspace ? [] : [.show(window)]
    }

    @discardableResult
    public mutating func switchTo(_ workspace: WorkspaceID, on display: DisplayID) throws -> [WindowTransition] {
        try validate(workspace, on: display)
        let previous = displays[display]!.active
        guard previous != workspace else { return [] }
        displays[display]!.active = workspace
        let owned = windows.keys.filter { windows[$0]?.display == display }.sorted { $0.rawValue < $1.rawValue }
        let leaving = owned.filter { windows[$0]?.workspace == previous }.map(WindowTransition.hide)
        let entering = owned.filter { windows[$0]?.workspace == workspace }.map(WindowTransition.show)
        return leaving + entering
    }

    private func validate(_ workspace: WorkspaceID, on display: DisplayID) throws {
        guard let state = displays[display] else { throw WorkspaceModelError.unknownDisplay(display) }
        guard state.workspaces.contains(workspace) else {
            throw WorkspaceModelError.unknownWorkspace(display, workspace)
        }
    }
}
