import CoreGraphics
import Foundation

// WC-11: macOS native window tabs (Terminal, Ghostty, Finder, TextEdit,
// Xcode). Every tab is its own AX window, settable, with the group's frame;
// a fresh `kAXWindowsAttribute` read lists only the front tab, while the
// handles of background tabs keep resolving. A group owns one slot in the
// layout, held by its front tab. Background tabs stay registered but are in
// no workspace: they are never laid out, parked, probed for render or
// written, and absence from a fresh list never purges them while a member of
// their group is listed.

/// Frames within this many points are the same frame (a tab group shares one).
public let tabFrameTolerance: CGFloat = 1

public func tabFramesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= tabFrameTolerance && abs(a.minY - b.minY) <= tabFrameTolerance
        && abs(a.width - b.width) <= tabFrameTolerance && abs(a.height - b.height) <= tabFrameTolerance
}

/// What the adapters read about one window of the app: its current frame
/// (nil: unreadable) and whether a fresh window list of its app shows it.
public struct TabMemberFact: Equatable, Sendable {
    public let id: WindowID
    public let frame: CGRect?
    public let listed: Bool

    public init(id: WindowID, frame: CGRect?, listed: Bool) {
        self.id = id
        self.frame = frame
        self.listed = listed
    }
}

/// The registered window an arrival is a new tab of, if any. The arrival
/// must be listed (it is the front tab now) and the sibling unlisted (it
/// went behind it) at the same frame within `tabFrameTolerance`. Two
/// separate windows of an app are both listed, so they never merge.
public func tabGroupToJoin(frame: CGRect, listed: Bool, siblings: [TabMemberFact]) -> WindowID? {
    guard listed else {
        return nil
    }
    return siblings.first { sibling in
        !sibling.listed && sibling.frame.map { tabFramesMatch($0, frame) } == true
    }?.id
}

/// Whether a group member moved out to its own window (a tab dragged out):
/// it is listed, another member is listed too (two windows on screen), and
/// its frame differs from every listed member's readable frame. A group
/// dragged as a whole shows one listed member and never splits.
public func tabMemberLeaves(frame: CGRect, listed: Bool, others: [TabMemberFact]) -> Bool {
    let shown = others.filter(\.listed)
    guard listed, !shown.isEmpty else {
        return false
    }
    return shown.allSatisfy { other in
        other.frame.map { !tabFramesMatch($0, frame) } ?? false
    }
}

/// One native tab group: its members in the order they joined, and the
/// front tab, the one macOS shows and the one holding the slot.
public struct TabGroup: Equatable, Sendable {
    public let id: Int
    public fileprivate(set) var members: [WindowID]
    public fileprivate(set) var front: WindowID

    /// The members macOS keeps behind the front tab.
    public var background: [WindowID] {
        members.filter { $0 != front }
    }
}

/// The slot moves from one member to another (`handOverTabSlot`).
public struct TabHandover: Equatable, Sendable {
    public let from: WindowID
    public let to: WindowID

    public init(from: WindowID, to: WindowID) {
        self.from = from
        self.to = to
    }
}

/// Every native tab group of the session. Pure value type: the discovery
/// service owns one; a group of one member dissolves.
public struct TabGroupBook: Equatable, Sendable {
    private var groups: [Int: TabGroup] = [:]
    private var groupOf: [WindowID: Int] = [:]
    private var nextID = 1

    public init() {}

    public func group(of id: WindowID) -> TabGroup? {
        groupOf[id].flatMap { groups[$0] }
    }

    /// A member macOS keeps behind its group's front tab.
    public func isBackground(_ id: WindowID) -> Bool {
        group(of: id).map { $0.front != id } ?? false
    }

    /// `id` (ungrouped) joins `member`'s group, a new one when `member` has
    /// none, as its front tab. Nil when `id` is already grouped or is `member`.
    @discardableResult
    public mutating func join(_ id: WindowID, with member: WindowID) -> (group: Int, handover: TabHandover)? {
        guard id != member, groupOf[id] == nil else {
            return nil
        }
        var group: TabGroup
        if let existing = self.group(of: member) {
            group = existing
        } else {
            group = TabGroup(id: nextID, members: [member], front: member)
            nextID += 1
            groupOf[member] = group.id
        }
        let handover = TabHandover(from: group.front, to: id)
        group.members.append(id)
        group.front = id
        groups[group.id] = group
        groupOf[id] = group.id
        return (group.id, handover)
    }

    /// A background member became the tab macOS shows. Nil for a front tab
    /// or an ungrouped window.
    @discardableResult
    public mutating func bringToFront(_ id: WindowID) -> TabHandover? {
        guard var group = group(of: id), group.front != id else {
            return nil
        }
        let handover = TabHandover(from: group.front, to: id)
        group.front = id
        groups[group.id] = group
        return handover
    }

    /// Members leave (closed, dragged out). A front tab whose group keeps a
    /// member hands the slot to `preferring` when it survives, else to the
    /// member after it in join order (else the one before); a focus event
    /// corrects that pick if macOS shows another one.
    @discardableResult
    public mutating func remove(_ ids: Set<WindowID>, preferring: WindowID? = nil) -> [TabHandover] {
        var handovers: [TabHandover] = []
        for groupID in Set(ids.compactMap { groupOf[$0] }).sorted() {
            guard var group = groups[groupID] else {
                continue
            }
            let survivors = group.members.filter { !ids.contains($0) }
            if ids.contains(group.front), !survivors.isEmpty {
                let index = group.members.firstIndex(of: group.front)!
                let after = group.members[(index + 1)...].first { !ids.contains($0) }
                let pick = preferring.flatMap { survivors.contains($0) ? $0 : nil } ?? after ?? survivors.last!
                handovers.append(TabHandover(from: group.front, to: pick))
                group.front = pick
            }
            for id in group.members where ids.contains(id) {
                groupOf.removeValue(forKey: id)
            }
            group.members = survivors
            if survivors.count < 2 {
                survivors.forEach { groupOf.removeValue(forKey: $0) }
                groups.removeValue(forKey: groupID)
            } else {
                groups[groupID] = group
            }
        }
        return handovers
    }

    /// Every member of a group with a `present` member: a complete scan
    /// lists only front tabs, so their background tabs are not gone.
    public func membersKept(present: Set<WindowID>) -> Set<WindowID> {
        Set(groups.values.filter { $0.members.contains(where: present.contains) }.flatMap(\.members))
    }
}

extension Workspace {
    /// `new` takes `old`'s exact place: its column position (stacked
    /// height weight included), the focus, and its dwindle leaf.
    mutating func replaceWindow(_ old: WindowID, with new: WindowID) {
        for index in columns.indices {
            guard let row = columns[index].windows.firstIndex(of: old) else {
                continue
            }
            columns[index].windows[row] = new
            if let weight = columns[index].heightWeights.removeValue(forKey: old) {
                columns[index].heightWeights[new] = weight
            }
        }
        if focusedWindow == old {
            focusedWindow = new
        }
        dwindle.root = dwindle.root?.swappingLeaves(old, new)
        if dwindle.selected == old {
            dwindle.selected = new
        }
        if dwindle.maximized == old {
            dwindle.maximized = new
        }
    }
}

/// Move a tab group's slot from one member to another, wherever the slot
/// is (any workspace, any display). False when no workspace holds `from`.
@discardableResult
public func handOverTabSlot(_ handover: TabHandover, manager: inout WorkspaceManager) -> Bool {
    var moved = false
    for candidate in manager.allWorkspaces where candidate.windows.contains(handover.from) {
        var workspace = candidate
        workspace.replaceWindow(handover.from, with: handover.to)
        manager.update(workspace)
        moved = true
    }
    return moved
}
