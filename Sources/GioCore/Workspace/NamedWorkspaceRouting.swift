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
    /// The display numbered `number` the way `[[workspace]] display` counts:
    /// 1 is the main display, the others follow in position order. Nil when
    /// no such display is connected.
    public func display(numbered number: Int) -> DisplayID? {
        guard let first = displayIDs.first, number >= 1 else {
            return nil
        }
        let main = mainDisplay.flatMap { displayIDs.contains($0) ? $0 : nil } ?? first
        let ranked = [main] + displayIDs.filter { $0 != main }
        return number <= ranked.count ? ranked[number - 1] : nil
    }

    /// Where a rule sends a window, nil when it routes nowhere valid. Its
    /// named workspace wins (on that workspace's display; WR-04: only when
    /// it lives on the rule's display, if the rule names a connected one),
    /// then the rule display (its stack's index `workspace = N`, else its
    /// shown workspace), then the index on the focused display.
    public func ruleDestination(_ outcome: RuleOutcome) -> WorkspaceID? {
        let ruleDisplay = outcome.display.flatMap { display(numbered: $0) }
        if let name = outcome.openOnWorkspace, let named = namedWorkspaceID(name),
           ruleDisplay == nil || location(of: named)?.display == ruleDisplay
        {
            return named
        }
        if let ruleDisplay {
            let ids = stack(on: ruleDisplay).map(\.id)
            if let index = outcome.workspace, index >= 1, !ids.isEmpty {
                return ids[min(index, ids.count) - 1]
            }
            return activeID(on: ruleDisplay)
        }
        return outcome.workspace.flatMap { ruleTarget($0) }
    }

    /// Where an arriving window goes: the rule's destination
    /// (`ruleDestination`), else the shown workspace of `display` (MM-01: a
    /// startup window's own display), else the current workspace (live
    /// arrivals pass nil: they land on the focused display; a rule display
    /// that is not connected falls back the same way).
    public func arrivalDestination(_ outcome: RuleOutcome, onDisplay display: DisplayID? = nil) -> WorkspaceID {
        ruleDestination(outcome) ?? display.flatMap { activeID(on: $0) } ?? currentID
    }
}
