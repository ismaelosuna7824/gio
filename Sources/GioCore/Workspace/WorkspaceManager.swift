import Foundation

/// NF-02 workspace manager: Niri-style dynamic vertical workspaces.
///
/// Each display owns an ordered stack of workspaces (top to bottom). Every
/// workspace keeps its own columns, windows, focus and viewport, and has a
/// stable `WorkspaceID` while its 1-based *index* in the stack shifts as
/// workspaces come and go.
///
/// Invariants after every operation, per stack:
/// - exactly one trailing empty workspace ends the stack (the "spare" a
///   window can be dropped into to open a new workspace);
/// - an empty workspace that is not the stack's active one is removed (Niri:
///   an emptied workspace disappears once you leave it);
/// - the active workspace may be empty only while you stay on it (it is
///   removed on leaving) or when it is the trailing one;
/// - windows are never lost: removal only ever drops empty workspaces, and a
///   disconnected display's windows merge into a surviving stack.
///
/// `current` is the focused display's active workspace. Its *index* is what
/// hotkeys, `gio workspace N` and status use; `currentID` is the stable
/// identity. The hosting session mirrors each display's `activeID` into
/// `DisplayState.workspace`.
public struct WorkspaceManager: Equatable, Sendable {
    /// Addressable indices for `workspace N`, `move-to-workspace N`, window
    /// rules and the CLI. An index beyond the stack lands on the trailing
    /// empty workspace, so the stack itself may be shorter (or, with many
    /// windows, longer) than this.
    public static let range = 1...9

    /// Stand-in display used until the host registers the real ones.
    public static let placeholderDisplay = DisplayID(0)

    private struct Stack: Equatable, Sendable {
        var ids: [WorkspaceID]
        var active: Int
    }

    private var workspaces: [WorkspaceID: Workspace]
    private var stacks: [DisplayID: Stack]
    private var order: [DisplayID]
    private var nextID: UInt64
    public private(set) var focusedDisplay: DisplayID

    public init() {
        let first = WorkspaceID(1)
        self.workspaces = [first: Workspace(id: first)]
        self.stacks = [Self.placeholderDisplay: Stack(ids: [first], active: 0)]
        self.order = [Self.placeholderDisplay]
        self.nextID = 2
        self.focusedDisplay = Self.placeholderDisplay
    }

    // MARK: - Reading

    /// Stable identity of the current workspace.
    public var currentID: WorkspaceID {
        activeID(on: focusedDisplay)!
    }

    /// 1-based index of the current workspace in the focused display's stack.
    public var current: Int {
        stacks[focusedDisplay]!.active + 1
    }

    public func currentWorkspace() -> Workspace {
        workspaces[currentID]!
    }

    /// Workspace at 1-based `index` in the focused display's stack.
    public func workspace(_ index: Int) -> Workspace? {
        workspace(index, on: focusedDisplay)
    }

    public func workspace(_ index: Int, on display: DisplayID) -> Workspace? {
        guard let stack = stacks[display], index >= 1, index <= stack.ids.count else {
            return nil
        }
        return workspaces[stack.ids[index - 1]]
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        workspaces[id]
    }

    /// Displays in registration order.
    public var displayIDs: [DisplayID] {
        order
    }

    /// The display's stack, top to bottom.
    public func stack(on display: DisplayID) -> [Workspace] {
        (stacks[display]?.ids ?? []).compactMap { workspaces[$0] }
    }

    public func activeID(on display: DisplayID) -> WorkspaceID? {
        stacks[display].map { $0.ids[$0.active] }
    }

    /// Active workspace of every display: the ones a reflow shows.
    public var activeIDs: Set<WorkspaceID> {
        Set(order.compactMap { activeID(on: $0) })
    }

    /// Every workspace, display by display, each stack top to bottom.
    public var allWorkspaces: [Workspace] {
        order.flatMap { stack(on: $0) }
    }

    /// Display owning the workspace and its 1-based index there.
    public func location(of id: WorkspaceID) -> (display: DisplayID, index: Int)? {
        for display in order {
            if let at = stacks[display]?.ids.firstIndex(of: id) {
                return (display, at + 1)
            }
        }
        return nil
    }

    // MARK: - Displays

    /// Reconcile the stacks with the connected displays (in the host's
    /// order). The placeholder stack is adopted by the first real display;
    /// new displays get a single empty workspace; a removed display's
    /// non-empty workspaces merge into the first surviving stack, above its
    /// trailing spare. An empty list changes nothing (a transient probe).
    public mutating func syncDisplays(_ ids: [DisplayID]) {
        guard !ids.isEmpty else {
            return
        }
        var wanted: [DisplayID] = []
        for id in ids where !wanted.contains(id) {
            wanted.append(id)
        }
        if order == [Self.placeholderDisplay], !wanted.contains(Self.placeholderDisplay) {
            let adopter = wanted[0]
            stacks[adopter] = stacks.removeValue(forKey: Self.placeholderDisplay)
            order = [adopter]
            focusedDisplay = adopter
        }
        for id in wanted where stacks[id] == nil {
            stacks[id] = Stack(ids: [spawnWorkspace()], active: 0)
            order.append(id)
        }
        let target = wanted.contains(focusedDisplay) ? focusedDisplay : wanted[0]
        for gone in order where !wanted.contains(gone) {
            guard let removed = stacks.removeValue(forKey: gone) else {
                continue
            }
            var host = stacks[target]!
            let hostActive = host.ids[host.active]
            for id in removed.ids {
                if workspaces[id]?.columns.isEmpty ?? true {
                    workspaces.removeValue(forKey: id)
                } else {
                    host.ids.append(id)
                }
            }
            host.active = host.ids.firstIndex(of: hostActive)!
            stacks[target] = host
            if gone == focusedDisplay {
                focusedDisplay = target
            }
        }
        order = order.filter { wanted.contains($0) }
        focusedDisplay = wanted.contains(focusedDisplay) ? focusedDisplay : target
        for display in order {
            normalize(display)
        }
    }

    // MARK: - Navigation

    /// Focus workspace `index` (1-based) of the focused display's stack. An
    /// index beyond the stack lands on the trailing empty workspace; below 1
    /// is refused. Leaving an empty workspace removes it.
    @discardableResult
    public mutating func switchTo(_ index: Int) -> Bool {
        guard index >= 1 else {
            return false
        }
        let stack = stacks[focusedDisplay]!
        activate(min(index, stack.ids.count) - 1, on: focusedDisplay)
        return true
    }

    /// Focus the workspace below. False at the bottom of the stack.
    @discardableResult
    public mutating func focusDown() -> Bool {
        let stack = stacks[focusedDisplay]!
        guard stack.active + 1 < stack.ids.count else {
            return false
        }
        activate(stack.active + 1, on: focusedDisplay)
        return true
    }

    /// Focus the workspace above. False at the top of the stack.
    @discardableResult
    public mutating func focusUp() -> Bool {
        let stack = stacks[focusedDisplay]!
        guard stack.active > 0 else {
            return false
        }
        activate(stack.active - 1, on: focusedDisplay)
        return true
    }

    /// Focus a specific workspace on whichever display owns it (focusing a
    /// window elsewhere). False when the id is unknown.
    @discardableResult
    public mutating func focus(_ id: WorkspaceID) -> Bool {
        guard let place = location(of: id) else {
            return false
        }
        focusedDisplay = place.display
        activate(place.index - 1, on: place.display)
        return true
    }

    // MARK: - Writing

    /// Write back a modified workspace. Unknown IDs are ignored: the manager
    /// owns its workspaces and never adopts foreign state. Restores the
    /// stack invariants (a filled spare grows a new spare; an emptied
    /// inactive workspace disappears).
    public mutating func update(_ workspace: Workspace) {
        guard workspaces[workspace.id] != nil, let place = location(of: workspace.id) else {
            return
        }
        workspaces[workspace.id] = workspace
        normalize(place.display)
    }

    /// Move a window from the current workspace to `index` of the focused
    /// display's stack (beyond the stack: the trailing empty workspace).
    /// Focus stays on the source. The window is extracted from its column
    /// (emptied columns removed, source focus repaired) and appended as a
    /// new last column at the destination, focused, carrying its height
    /// weight. False when the index is below 1, resolves to the current
    /// workspace, or the window is not in the current workspace.
    @discardableResult
    public mutating func moveWindow(_ id: WindowID, to index: Int) -> Bool {
        guard index >= 1 else {
            return false
        }
        let stack = stacks[focusedDisplay]!
        let destination = stack.ids[min(index, stack.ids.count) - 1]
        return transfer(id, to: destination, follow: false)
    }

    /// Move the window one workspace down (a new workspace opens when it
    /// lands in the spare) and follow it there. False at the bottom.
    @discardableResult
    public mutating func moveWindowDown(_ id: WindowID) -> Bool {
        let stack = stacks[focusedDisplay]!
        guard stack.active + 1 < stack.ids.count else {
            return false
        }
        return transfer(id, to: stack.ids[stack.active + 1], follow: true)
    }

    /// Move the window one workspace up and follow it there. False at the top.
    @discardableResult
    public mutating func moveWindowUp(_ id: WindowID) -> Bool {
        let stack = stacks[focusedDisplay]!
        guard stack.active > 0 else {
            return false
        }
        return transfer(id, to: stack.ids[stack.active - 1], follow: true)
    }

    /// The workspace a window rule `workspace = N` targets: index N of the
    /// focused display's stack, or the trailing empty one when N is beyond it.
    /// Nil for indices below 1.
    public func ruleTarget(_ index: Int) -> WorkspaceID? {
        guard index >= 1 else {
            return nil
        }
        let stack = stacks[focusedDisplay]!
        return stack.ids[min(index, stack.ids.count) - 1]
    }

    // MARK: - Internals

    private mutating func spawnWorkspace() -> WorkspaceID {
        let id = WorkspaceID(nextID)
        nextID += 1
        workspaces[id] = Workspace(id: id)
        return id
    }

    private mutating func activate(_ position: Int, on display: DisplayID) {
        var stack = stacks[display]!
        stack.active = position
        stacks[display] = stack
        normalize(display)
    }

    /// Drop empty inactive workspaces, then make sure a spare ends the stack.
    private mutating func normalize(_ display: DisplayID) {
        guard var stack = stacks[display] else {
            return
        }
        let active = stack.ids[stack.active]
        var kept: [WorkspaceID] = []
        for id in stack.ids {
            if id == active || !(workspaces[id]?.columns.isEmpty ?? true) {
                kept.append(id)
            } else {
                workspaces.removeValue(forKey: id)
            }
        }
        if let last = kept.last, !(workspaces[last]?.columns.isEmpty ?? true) {
            kept.append(spawnWorkspace())
        }
        stack.ids = kept
        stack.active = kept.firstIndex(of: active)!
        stacks[display] = stack
    }

    private mutating func transfer(_ id: WindowID, to destinationID: WorkspaceID, follow: Bool) -> Bool {
        let sourceID = currentID
        guard destinationID != sourceID,
              var source = workspaces[sourceID],
              let (colIdx, rowIdx) = locate(id, in: source)
        else {
            return false
        }
        var scol = source.columns[colIdx]
        let weight = scol.heightWeights[id]
        scol.windows.remove(at: rowIdx)
        if weight != nil {
            scol.heightWeights.removeValue(forKey: id)
        }
        if scol.windows.isEmpty {
            source.columns.remove(at: colIdx)
        } else {
            if scol.focusedWindowIndex == rowIdx {
                scol.focusedWindowIndex = min(rowIdx, scol.windows.count - 1)
            } else if scol.focusedWindowIndex > rowIdx {
                scol.focusedWindowIndex -= 1
            }
            source.columns[colIdx] = scol
        }
        if source.columns.isEmpty {
            source.focusedColumn = 0
            source.focusedWindow = nil
        } else {
            if source.focusedColumn >= source.columns.count {
                source.focusedColumn = source.columns.count - 1
            }
            if source.focusedWindow == id {
                source.focusedWindow = source.columns[source.focusedColumn].focusedWindowID
            }
        }
        workspaces[sourceID] = source

        var dest = workspaces[destinationID]!
        var created = Column(
            id: ColumnID((dest.columns.map(\.id.rawValue).max() ?? 0) + 1),
            width: 0,
            windows: [id]
        )
        if let weight {
            created.heightWeights[id] = weight
        }
        dest.columns.append(created)
        dest.focusedColumn = dest.columns.count - 1
        dest.focusedWindow = id
        workspaces[destinationID] = dest

        if follow, let place = location(of: destinationID) {
            activate(place.index - 1, on: place.display)
        } else {
            normalize(focusedDisplay)
        }
        return true
    }

    private func locate(_ id: WindowID, in workspace: Workspace) -> (Int, Int)? {
        for (colIdx, column) in workspace.columns.enumerated() {
            if let rowIdx = column.windows.firstIndex(of: id) {
                return (colIdx, rowIdx)
            }
        }
        return nil
    }
}
