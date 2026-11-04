/// Whether Gio may lay out and move windows now. Two reasons pause it: the
/// managed Space is not the active one, or (WC-22) another window manager
/// runs and would fight Gio over the same windows. A transition is reported
/// only when the combined answer changes.
public struct SpaceGate: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case unchanged
        case left
        case returned
    }

    public private(set) var isManagedActive: Bool
    /// WC-22: the other window managers running, sorted.
    public private(set) var conflicts: [String] = []

    public init(isManagedActive: Bool = true) {
        self.isManagedActive = isManagedActive
    }

    public var allowsWindowWork: Bool {
        isManagedActive && conflicts.isEmpty
    }

    public mutating func update(managedActive: Bool) -> Transition {
        let before = allowsWindowWork
        isManagedActive = managedActive
        return transition(from: before)
    }

    public mutating func update(conflicts: [String]) -> Transition {
        let before = allowsWindowWork
        self.conflicts = conflicts
        return transition(from: before)
    }

    private func transition(from before: Bool) -> Transition {
        switch (before, allowsWindowWork) {
        case (true, false): return .left
        case (false, true): return .returned
        default: return .unchanged
        }
    }
}

/// WC-22: window managers that move other apps' windows, by process name
/// (the name the system lists; yabai runs as a plain daemon, the others as
/// apps). Only names known to be window managers: a snapping utility is not
/// one.
public let knownWindowManagerProcessNames = ["AeroSpace", "Amethyst", "OmniWM", "yabai"]

/// WC-22: the known window managers among the running processes, sorted.
public func conflictingWindowManagers(runningProcessNames: Set<String>) -> [String] {
    knownWindowManagerProcessNames.filter(runningProcessNames.contains).sorted()
}
