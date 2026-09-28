import Foundation

/// Plan §15 workspace manager: nine persistent workspaces (1...9),
/// pre-created empty, current starting at 1. Each workspace keeps its own
/// columns, windows, focus and viewport — switching never mixes them.
/// Hotkey bindings (Alt+N / Alt+Shift+N) arrive in Phase 13; this type only
/// switches state and moves windows between workspaces.
public struct WorkspaceManager: Equatable, Sendable {
    public static let range = 1...9

    private var workspaces: [Int: Workspace]
    public private(set) var current: Int

    public init() {
        var all: [Int: Workspace] = [:]
        for index in Self.range {
            all[index] = Workspace(id: WorkspaceID(UInt64(index)))
        }
        self.workspaces = all
        self.current = 1
    }

    public func workspace(_ index: Int) -> Workspace? {
        workspaces[index]
    }

    public func currentWorkspace() -> Workspace {
        workspaces[current]!
    }

    /// Switch the current workspace. False outside 1...9, current unchanged.
    @discardableResult
    public mutating func switchTo(_ index: Int) -> Bool {
        guard Self.range.contains(index) else {
            return false
        }
        current = index
        return true
    }

    /// Write back a modified workspace. Unknown IDs are ignored: the manager
    /// owns 1...9 and never adopts foreign state.
    public mutating func update(_ workspace: Workspace) {
        let index = Int(workspace.id.rawValue)
        guard Self.range.contains(index) else {
            return
        }
        workspaces[index] = workspace
    }

    /// Move a window from the current workspace to another: extracted from
    /// its column (emptied columns removed, source focus repaired) and
    /// appended as a new last column at the destination, focused, carrying
    /// its height weight. False when the index is out of range, equals the
    /// current workspace, or the window is not in the current workspace.
    @discardableResult
    public mutating func moveWindow(_ id: WindowID, to index: Int) -> Bool {
        guard Self.range.contains(index), index != current else {
            return false
        }
        guard var source = workspaces[current],
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
        workspaces[current] = source

        var dest = workspaces[index]!
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
        workspaces[index] = dest
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
