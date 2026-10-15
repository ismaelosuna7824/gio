import Foundation

// WR-03..WR-05: how a rule shapes a new window's column, where it opens and
// whether it takes the strip's focus, plus the one title re-check for
// windows that appear before their title (Chrome, Electron apps).

/// Whether an arriving window becomes its workspace's focused window: never
/// a minimized or floating arrival (a dialog or a transient popup must not
/// take the strip's focus), and never against `open-focused = false`.
public func arrivalTakesFocus(_ outcome: RuleOutcome, mode: WindowMode, minimized: Bool) -> Bool {
    outcome.openFocused && !minimized && mode != .floating
}

/// Where a rule may send an arriving window. A window discovery floated (a
/// dialog, a panel, a fixed-size popup such as Chrome's address-bar
/// suggestions, re-created on every key) of an app that already has a window
/// belongs with the window it came from: it opens where the user is, never
/// on the rule's workspace or display, so it never takes the user there
/// either. An app's only window is the app, whatever it reports (Music's
/// main window is a dialog): the rule places it. A rule that floats the
/// window itself (`mode = "floating"`) keeps its placement.
public func arrivalPlacement(
    _ outcome: RuleOutcome, admissionFloat: FloatReason?, appHasOtherWindows: Bool
) -> RuleOutcome {
    guard appHasOtherWindows, let reason = admissionFloat, reason.isAdmission, outcome.mode != .floating else {
        return outcome
    }
    var placement = outcome
    placement.workspace = nil
    placement.openOnWorkspace = nil
    placement.display = nil
    return placement
}

/// Apply the rule's width and maximized state to a column. Maximized is
/// exactly the `maximize-column` state: full strip width, the rule width
/// (or the default) saved for the toggle back.
func shapeArrivalColumn(_ column: inout Column, outcome: RuleOutcome) {
    let width = outcome.columnWidth ?? .standard
    column.widthSpec = outcome.openMaximized ? .proportion(1) : width
    if outcome.openMaximized {
        column.savedWidthSpec = width
    }
}

func appendArrivalColumn(_ id: WindowID, outcome: RuleOutcome, to workspace: inout Workspace, focus: Bool) {
    var column = Column(
        id: ColumnID((workspace.columns.map(\.id.rawValue).max() ?? 0) + 1),
        width: 0, windows: [id]
    )
    column.focusedWindowIndex = 0
    shapeArrivalColumn(&column, outcome: outcome)
    workspace.columns.append(column)
    if focus {
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindow = id
    }
}

/// Put an arriving window in a new last column of its destination
/// (`arrivalDestination`), shaped by the rule. `takesFocus` makes it the
/// destination's focused window; the focused display never changes here
/// (following is the caller's decision). Returns the destination.
@discardableResult
public func placeArrival(
    _ id: WindowID, outcome: RuleOutcome, takesFocus: Bool, onDisplay display: DisplayID? = nil,
    manager: inout WorkspaceManager
) -> WorkspaceID {
    let destID = manager.arrivalDestination(outcome, onDisplay: display)
    guard var dest = manager.workspace(id: destID) else {
        return destID
    }
    appendArrivalColumn(id, outcome: outcome, to: &dest, focus: takesFocus)
    manager.update(dest)
    return destID
}

// MARK: - Title re-check

/// WR-01: windows registered with an empty title, armed for one re-check
/// when their title first becomes non-empty within `window` seconds.
public struct TitleRecheckBook: Sendable {
    public static let window: TimeInterval = 1

    private var armed: [WindowID: TimeInterval] = [:]

    public init() {}

    public mutating func arm(_ id: WindowID, at time: TimeInterval) {
        armed = armed.filter { time - $0.value <= Self.window }
        armed[id] = time
    }

    /// True once, for an armed window inside the window; disarms it either way.
    public mutating func take(_ id: WindowID, now: TimeInterval) -> Bool {
        guard let armedAt = armed.removeValue(forKey: id) else {
            return false
        }
        return now - armedAt <= Self.window
    }

    /// PF-W: armed and inside the window (its title is wanted right away).
    public func isArmed(_ id: WindowID, now: TimeInterval) -> Bool {
        armed[id].map { now - $0 <= Self.window } ?? false
    }

    public mutating func forget(_ id: WindowID) {
        armed.removeValue(forKey: id)
    }
}

/// Arm a re-check only for an untitled arrival while some rule has a title
/// matcher (no title rule, nothing a title could change).
public func titleRecheckWanted(rules: [WindowRule], title: String) -> Bool {
    title.isEmpty && rules.contains { $0.title != nil }
}

/// The re-check's verdict: an outcome only when a title rule now wins.
/// Rules without a title matched (or not) the same way at registration,
/// and title rules could not match the empty title then, so the verdict
/// changed exactly when the winner is a title rule.
public func titleRecheckOutcome(_ rules: [WindowRule], window: ManagedWindow) -> RuleOutcome? {
    let outcome = evaluateRules(rules, app: window.application, bundleID: window.bundleID, title: window.title)
    return outcome.matchedByTitle ? outcome : nil
}

/// Apply a re-check verdict: mode (a rule float or back to tiled; admission
/// floats are never relabeled), width limits, and the column (moved to the
/// rule's workspace or display as a new column, else reshaped in place when
/// it holds only this window). Never focuses and never follows: the
/// current workspace and the strip's focused window stay unless the window
/// itself leaves (its workspace's focus then falls to a neighbour).
public func applyTitleRecheck(
    _ id: WindowID, outcome: RuleOutcome, registry: WindowRegistry, manager: inout WorkspaceManager
) {
    if var record = registry.find(id) {
        record.widthLimits = outcome.widthLimits
        switch outcome.mode {
        case .floating? where record.mode == .tiled:
            record.mode = .floating
            record.floatReason = .rule
        case .tiled? where record.mode == .floating && record.floatReason == .rule:
            record.mode = .tiled
            record.floatReason = nil
        default:
            break
        }
        try? registry.update(record)
    }
    guard var source = manager.allWorkspaces.first(where: { $0.columns.contains { $0.windows.contains(id) } })
    else {
        return
    }
    let placement = arrivalPlacement(
        outcome, admissionFloat: registry.find(id)?.floatReason,
        appHasOtherWindows: registry.managedWindows().contains { $0.pid == id.pid && $0.id != id }
    )
    let destID = manager.ruleDestination(placement) ?? source.id
    if destID == source.id {
        guard let index = source.columns.firstIndex(where: { $0.windows == [id] }) else {
            return
        }
        shapeArrivalColumn(&source.columns[index], outcome: outcome)
        manager.update(source)
        return
    }
    source.stripWindows([id])
    manager.update(source)
    // Updating the source may re-create the trailing spare: resolve again.
    guard var dest = manager.workspace(id: manager.ruleDestination(placement) ?? destID) else {
        return
    }
    appendArrivalColumn(id, outcome: outcome, to: &dest, focus: false)
    manager.update(dest)
}
