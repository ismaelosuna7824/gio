import Foundation

/// NW-02: whether a window arriving on its `open-on-workspace` destination
/// takes the user there. `whenActive` follows only when the window's app is
/// frontmost as it appears (the user just launched or used it).
public func shouldFollowArrival(
    _ policy: WorkspaceFollowPolicy, windowPID: pid_t, frontmostPID: pid_t?
) -> Bool {
    switch policy {
    case .always: return true
    case .never: return false
    case .whenActive: return frontmostPID == windowPID
    }
}

extension WorkspaceManager {
    /// Where an arriving window goes: its rule's named workspace (on that
    /// workspace's display) when it exists, else the rule's index on the
    /// focused display (`workspace = N`), else the shown workspace of
    /// `display` (MM-01: a startup window's own display), else the current
    /// workspace (live arrivals pass nil: they land on the focused display).
    public func arrivalDestination(_ outcome: RuleOutcome, onDisplay display: DisplayID? = nil) -> WorkspaceID {
        if let name = outcome.openOnWorkspace, let named = namedWorkspaceID(name) {
            return named
        }
        if let index = outcome.workspace, let target = ruleTarget(index) {
            return target
        }
        return display.flatMap { activeID(on: $0) } ?? currentID
    }
}
