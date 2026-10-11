import Foundation

/// Reference grouping for the Shortcuts screen, in display order.
public enum ShortcutCategory: CaseIterable, Sendable {
    case focus, move, columns, windows, workspaces, monitors, app

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .move: return "Move"
        case .columns: return "Columns"
        case .windows: return "Windows"
        case .workspaces: return "Workspaces"
        case .monitors: return "Monitors"
        case .app: return "App"
        }
    }
}

public enum ShortcutSource: Equatable, Sendable {
    case `default`
    case config
}

public struct ShortcutBinding: Equatable, Sendable {
    public let combo: HotkeyCombo
    public let source: ShortcutSource

    public init(combo: HotkeyCombo, source: ShortcutSource) {
        self.combo = combo
        self.source = source
    }
}

/// One row of the Shortcuts reference. Parameterized actions (`workspace N`,
/// `move-to-workspace N`, `move-column-to-workspace N`) are one entry with
/// several bindings.
public struct ShortcutEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let category: ShortcutCategory
    /// The spelling used in `config.toml`; nil for shortcuts the config cannot rebind.
    public let configName: String?
    public let bindings: [ShortcutBinding]
    /// DA-07: the representative action (`workspace(1)` for `workspace N`);
    /// nil for the launcher, which the config cannot rebind.
    public let action: HotkeyAction?
    /// DA-07: default combos of this action that config set to `"none"`.
    public let removedDefaults: [HotkeyCombo]
}

private struct ActionInfo {
    let id: String
    let name: String
    let summary: String
    let category: ShortcutCategory
}

/// Exhaustive on purpose: adding a `HotkeyAction` case fails to compile here
/// until it is documented for the Shortcuts screen.
private func actionInfo(_ action: HotkeyAction) -> ActionInfo {
    switch action {
    case .focusLeft:
        return ActionInfo(id: "focus-left", name: "Focus left", summary: "Focus the column to the left.", category: .focus)
    case .focusRight:
        return ActionInfo(id: "focus-right", name: "Focus right", summary: "Focus the column to the right.", category: .focus)
    case .focusUp:
        return ActionInfo(id: "focus-up", name: "Focus up", summary: "Focus the window above in the current column.", category: .focus)
    case .focusDown:
        return ActionInfo(id: "focus-down", name: "Focus down", summary: "Focus the window below in the current column.", category: .focus)
    case .moveColumnLeft:
        return ActionInfo(id: "move-column-left", name: "Move column left", summary: "Swap the focused window's column with the one on its left; the column keeps its windows and sizes. With move-crosses-monitor-at-edge on, the first column goes to the display on the left.", category: .move)
    case .moveColumnRight:
        return ActionInfo(id: "move-column-right", name: "Move column right", summary: "Swap the focused window's column with the one on its right; the column keeps its windows and sizes. With move-crosses-monitor-at-edge on, the last column goes to the display on the right.", category: .move)
    case .moveLeft:
        return ActionInfo(id: "move-window-left", name: "Move window into left column", summary: "Append the focused window to the left column (unbound by default; use consume-or-expel instead).", category: .move)
    case .moveRight:
        return ActionInfo(id: "move-window-right", name: "Move window into right column", summary: "Append the focused window to the right column (unbound by default; use consume-or-expel instead).", category: .move)
    case .moveUp:
        return ActionInfo(id: "move-up", name: "Move window up", summary: "Move the focused window up within its column.", category: .move)
    case .moveDown:
        return ActionInfo(id: "move-down", name: "Move window down", summary: "Move the focused window down within its column.", category: .move)
    case .workspace:
        return ActionInfo(id: "workspace N", name: "Go to workspace N", summary: "Switch to workspace 1 to 9.", category: .workspaces)
    case .moveToWorkspace:
        return ActionInfo(id: "move-to-workspace N", name: "Move window to workspace N", summary: "Send the focused window to workspace 1 to 9.", category: .workspaces)
    case .focusWorkspaceDown:
        return ActionInfo(id: "focus-workspace-down", name: "Workspace down", summary: "Focus the workspace below in this display's stack.", category: .workspaces)
    case .focusWorkspaceUp:
        return ActionInfo(id: "focus-workspace-up", name: "Workspace up", summary: "Focus the workspace above in this display's stack.", category: .workspaces)
    case .moveWindowToWorkspaceDown:
        return ActionInfo(id: "move-window-to-workspace-down", name: "Move window down a workspace", summary: "Send the focused window to the workspace below (the empty one at the bottom opens a new workspace) and follow it.", category: .workspaces)
    case .moveWindowToWorkspaceUp:
        return ActionInfo(id: "move-window-to-workspace-up", name: "Move window up a workspace", summary: "Send the focused window to the workspace above and follow it.", category: .workspaces)
    case .toggleFloating:
        return ActionInfo(id: "toggle-floating", name: "Toggle floating", summary: "Switch the focused window between tiled and floating.", category: .windows)
    case .fullscreen:
        return ActionInfo(id: "fullscreen", name: "Fullscreen", summary: "Toggle fullscreen for the focused window.", category: .windows)
    case .switchPresetColumnWidth:
        return ActionInfo(id: "switch-preset-column-width", name: "Cycle column width", summary: "Cycle the focused column through the preset widths.", category: .columns)
    case .shrinkColumnWidth:
        return ActionInfo(id: "set-column-width-minus", name: "Shrink column", summary: "Make the focused column 10% narrower.", category: .columns)
    case .growColumnWidth:
        return ActionInfo(id: "set-column-width-plus", name: "Grow column", summary: "Make the focused column 10% wider.", category: .columns)
    case .maximizeColumn:
        return ActionInfo(id: "maximize-column", name: "Maximize column", summary: "Make the focused column fill the display width, again to restore.", category: .columns)
    case .centerColumn:
        return ActionInfo(id: "center-column", name: "Center column", summary: "Scroll the view so the focused column is centered.", category: .columns)
    case .consumeOrExpelLeft:
        return ActionInfo(id: "consume-or-expel-window-left", name: "Consume or expel left", summary: "Pull the window into the left column, or push it out into its own column.", category: .columns)
    case .consumeOrExpelRight:
        return ActionInfo(id: "consume-or-expel-window-right", name: "Consume or expel right", summary: "Pull the window into the right column, or push it out into its own column.", category: .columns)
    case .toggleOverview:
        return ActionInfo(id: "toggle-overview", name: "Workspace overview", summary: "Show every workspace of this display as a row of window thumbnails; pick one to go there.", category: .workspaces)
    case .focusMonitor(let direction):
        let side = monitorSide(direction)
        return ActionInfo(id: "focus-monitor-\(side)", name: "Focus monitor \(side)", summary: "Focus the display \(monitorPlace(direction)) and the workspace it shows (no display there: nothing happens).", category: .monitors)
    case .moveColumnToMonitor(let direction):
        let side = monitorSide(direction)
        return ActionInfo(id: "move-column-to-monitor-\(side)", name: "Move column to monitor \(side)", summary: "Send the focused column, with all its windows and its width, to the workspace the display \(monitorPlace(direction)) shows, next to its focused column, and follow it.", category: .monitors)
    case .moveWindowToMonitor(let direction):
        let side = monitorSide(direction)
        return ActionInfo(id: "move-window-to-monitor-\(side)", name: "Move window to monitor \(side)", summary: "Send only the focused window, as its own column, to the workspace the display \(monitorPlace(direction)) shows, and follow it (unbound by default).", category: .monitors)
    case .moveWorkspaceToMonitor(let direction):
        let side = monitorSide(direction)
        return ActionInfo(id: "move-workspace-to-monitor-\(side)", name: "Move workspace to monitor \(side)", summary: "Send the current workspace to the stack of the display \(monitorPlace(direction)), shown there, and follow it; named workspaces stay where config puts them (unbound by default).", category: .monitors)
    case .switchPresetWindowHeight:
        return ActionInfo(id: "switch-preset-window-height", name: "Cycle window height", summary: "Cycle the focused window through the preset heights of its column; the other windows share the rest.", category: .windows)
    case .shrinkWindowHeight:
        return ActionInfo(id: "set-window-height-minus", name: "Shrink window height", summary: "Make the focused window 10% of the column shorter; the others grow.", category: .windows)
    case .growWindowHeight:
        return ActionInfo(id: "set-window-height-plus", name: "Grow window height", summary: "Make the focused window 10% of the column taller; every other window keeps a minimum height.", category: .windows)
    case .resetWindowHeight:
        return ActionInfo(id: "reset-window-height", name: "Reset window heights", summary: "Give every window of the focused column an equal share of its height again.", category: .windows)
    case .focusColumnFirst:
        return ActionInfo(id: "focus-column-first", name: "Focus first column", summary: "Focus the leftmost column of the workspace.", category: .focus)
    case .focusColumnLast:
        return ActionInfo(id: "focus-column-last", name: "Focus last column", summary: "Focus the rightmost column of the workspace.", category: .focus)
    case .moveColumnToFirst:
        return ActionInfo(id: "move-column-to-first", name: "Move column to first", summary: "Move the focused column to the start of the strip; it keeps its windows and sizes.", category: .move)
    case .moveColumnToLast:
        return ActionInfo(id: "move-column-to-last", name: "Move column to last", summary: "Move the focused column to the end of the strip; it keeps its windows and sizes.", category: .move)
    case .swapWindowLeft:
        return ActionInfo(id: "swap-window-left", name: "Swap window left", summary: "Trade places with the focused window of the left column; widths stay with the columns (unbound by default).", category: .move)
    case .swapWindowRight:
        return ActionInfo(id: "swap-window-right", name: "Swap window right", summary: "Trade places with the focused window of the right column; widths stay with the columns (unbound by default).", category: .move)
    case .moveColumnToWorkspace:
        return ActionInfo(id: "move-column-to-workspace N", name: "Move column to workspace N", summary: "Send the focused column, with all its windows and sizes, to workspace 1 to 9 and follow it.", category: .workspaces)
    case .moveColumnToWorkspaceDown:
        return ActionInfo(id: "move-column-to-workspace-down", name: "Move column down a workspace", summary: "Send the focused column to the workspace below (the empty one at the bottom opens a new workspace) and follow it.", category: .workspaces)
    case .moveColumnToWorkspaceUp:
        return ActionInfo(id: "move-column-to-workspace-up", name: "Move column up a workspace", summary: "Send the focused column to the workspace above and follow it.", category: .workspaces)
    case .focusWorkspacePrevious:
        return ActionInfo(id: "focus-workspace-previous", name: "Previous workspace", summary: "Go back to the workspace this display showed before; again to return (unbound by default: Option+Tab belongs to app switchers).", category: .workspaces)
    case .moveWorkspaceDown:
        return ActionInfo(id: "move-workspace-down", name: "Move workspace down", summary: "Move the current workspace one place down in this display's stack; named workspaces keep their config order.", category: .workspaces)
    case .moveWorkspaceUp:
        return ActionInfo(id: "move-workspace-up", name: "Move workspace up", summary: "Move the current workspace one place up in this display's stack, never above the named ones.", category: .workspaces)
    case .focusWindowOrWorkspaceDown:
        return ActionInfo(id: "focus-window-or-workspace-down", name: "Focus down or workspace below", summary: "Focus the window below in the column; from its last window, the workspace below (unbound by default).", category: .focus)
    case .focusWindowOrWorkspaceUp:
        return ActionInfo(id: "focus-window-or-workspace-up", name: "Focus up or workspace above", summary: "Focus the window above in the column; from its first window, the workspace above (unbound by default).", category: .focus)
    case .switchPresetColumnWidthBack:
        return ActionInfo(id: "switch-preset-column-width-back", name: "Cycle column width back", summary: "Cycle the focused column through the preset widths in reverse (unbound by default).", category: .columns)
    case .expandColumnToAvailableWidth:
        return ActionInfo(id: "expand-column-to-available-width", name: "Expand column to available width", summary: "Make the focused column fill the space the other fully visible columns leave.", category: .columns)
    case .centerVisibleColumns:
        return ActionInfo(id: "center-visible-columns", name: "Center visible columns", summary: "Scroll the view so the fully visible columns sit in the middle of the display.", category: .columns)
    case .moveColumnLeftOrToMonitorLeft:
        return ActionInfo(id: "move-column-left-or-to-monitor-left", name: "Move column left or to monitor left", summary: "Move the column left; from the first column, send it to the display on the left as its last column, and follow it (unbound by default).", category: .monitors)
    case .moveColumnRightOrToMonitorRight:
        return ActionInfo(id: "move-column-right-or-to-monitor-right", name: "Move column right or to monitor right", summary: "Move the column right; from the last column, send it to the display on the right as its first column, and follow it (unbound by default).", category: .monitors)
    case .focusColumnOrMonitorLeft:
        return ActionInfo(id: "focus-column-or-monitor-left", name: "Focus column or monitor left", summary: "Focus the column on the left; from the first column, the display on the left (unbound by default).", category: .monitors)
    case .focusColumnOrMonitorRight:
        return ActionInfo(id: "focus-column-or-monitor-right", name: "Focus column or monitor right", summary: "Focus the column on the right; from the last column, the display on the right (unbound by default).", category: .monitors)
    }
}

/// The config-name suffix of a monitor direction.
private func monitorSide(_ direction: FocusDirection) -> String {
    switch direction {
    case .left: return "left"
    case .right: return "right"
    case .up: return "up"
    case .down: return "down"
    }
}

/// Where the neighbouring display sits, for the summaries.
private func monitorPlace(_ direction: FocusDirection) -> String {
    switch direction {
    case .left: return "on the left"
    case .right: return "on the right"
    case .up: return "above"
    case .down: return "below"
    }
}

/// Stable id of the entry an action belongs to (`workspace(3)` and
/// `workspace(5)` share one).
public func shortcutFamily(of action: HotkeyAction) -> String {
    actionInfo(action).id
}

/// DA-07: the `[keybindings]` value for an action (`workspace 3`).
public func configActionName(_ action: HotkeyAction) -> String {
    withParameter(actionInfo(action).id, of: action)
}

/// DA-07: the action's name for messages (`Go to workspace 3`).
public func shortcutActionTitle(_ action: HotkeyAction) -> String {
    withParameter(actionInfo(action).name, of: action)
}

/// Parameterized families spell their number as a trailing ` N`.
private func withParameter(_ text: String, of action: HotkeyAction) -> String {
    let number = parameter(of: action)
    guard number > 0, text.hasSuffix(" N") else {
        return text
    }
    return text.dropLast().appending("\(number)")
}

/// One representative per family, in display order within each category.
private let catalogActions: [HotkeyAction] = [
    .focusLeft, .focusRight, .focusUp, .focusDown, .focusColumnFirst, .focusColumnLast,
    .focusWindowOrWorkspaceDown, .focusWindowOrWorkspaceUp,
    .moveColumnLeft, .moveColumnRight, .moveColumnToFirst, .moveColumnToLast,
    .moveLeft, .moveRight, .moveUp, .moveDown, .swapWindowLeft, .swapWindowRight,
    .switchPresetColumnWidth, .switchPresetColumnWidthBack, .shrinkColumnWidth, .growColumnWidth,
    .maximizeColumn, .expandColumnToAvailableWidth, .centerColumn, .centerVisibleColumns,
    .consumeOrExpelLeft, .consumeOrExpelRight,
    .toggleFloating, .fullscreen,
    .switchPresetWindowHeight, .shrinkWindowHeight, .growWindowHeight, .resetWindowHeight,
    .workspace(1), .moveToWorkspace(1), .moveColumnToWorkspace(1),
    .focusWorkspaceDown, .focusWorkspaceUp, .focusWorkspacePrevious,
    .moveWindowToWorkspaceDown, .moveWindowToWorkspaceUp,
    .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp,
    .moveWorkspaceDown, .moveWorkspaceUp, .toggleOverview,
    .focusMonitor(.left), .focusMonitor(.right), .focusMonitor(.up), .focusMonitor(.down),
    .moveColumnToMonitor(.left), .moveColumnToMonitor(.right),
    .moveColumnToMonitor(.up), .moveColumnToMonitor(.down),
    .moveWindowToMonitor(.left), .moveWindowToMonitor(.right),
    .moveWindowToMonitor(.up), .moveWindowToMonitor(.down),
    .moveWorkspaceToMonitor(.left), .moveWorkspaceToMonitor(.right),
    .moveWorkspaceToMonitor(.up), .moveWorkspaceToMonitor(.down),
    .moveColumnLeftOrToMonitorLeft, .moveColumnRightOrToMonitorRight,
    .focusColumnOrMonitorLeft, .focusColumnOrMonitorRight,
]

/// Effective bindings: defaults minus `"none"` combos, with config bindings
/// layered on top (later wins, one action per combo), grouped by action,
/// each marked by origin.
public func shortcutCatalog(
    configKeybindings: [(HotkeyCombo, HotkeyAction)], unbound: [HotkeyCombo] = []
) -> [ShortcutEntry] {
    let effective = effectiveHotkeyBindings(configKeybindings: configKeybindings, unbound: unbound)
    var byFamily: [String: [(combo: HotkeyCombo, action: HotkeyAction, source: ShortcutSource)]] = [:]
    for (combo, value) in effective {
        byFamily[shortcutFamily(of: value.action), default: []]
            .append((combo, value.action, value.source))
    }
    let unboundSet = Set(unbound)
    var removedByFamily: [String: [(combo: HotkeyCombo, action: HotkeyAction)]] = [:]
    for (combo, action) in defaultHotkeyBindings() where unboundSet.contains(combo) {
        removedByFamily[shortcutFamily(of: action), default: []].append((combo, action))
    }
    var entries: [ShortcutEntry] = catalogActions.map { representative in
        let info = actionInfo(representative)
        let bindings = (byFamily[info.id] ?? []).sorted(by: bindingOrder)
            .map { ShortcutBinding(combo: $0.combo, source: $0.source) }
        let removed = (removedByFamily[info.id] ?? []).map { ($0.combo, $0.action, ShortcutSource.default) }
            .sorted(by: bindingOrder).map(\.0)
        return ShortcutEntry(
            id: info.id, name: info.name, summary: info.summary,
            category: info.category, configName: info.id, bindings: bindings,
            action: representative, removedDefaults: removed
        )
    }
    entries.append(ShortcutEntry(
        id: "launcher", name: "Open launcher",
        summary: "Summon the launcher panel to search and open apps and windows.",
        category: .app, configName: nil,
        bindings: [ShortcutBinding(combo: launcherHotkey, source: .default)],
        action: nil, removedDefaults: []
    ))
    return entries
}

/// Family order: parameter first (workspace 1…9), then the combo text.
private func bindingOrder(
    _ lhs: (combo: HotkeyCombo, action: HotkeyAction, source: ShortcutSource),
    _ rhs: (combo: HotkeyCombo, action: HotkeyAction, source: ShortcutSource)
) -> Bool {
    let (l, r) = (parameter(of: lhs.action), parameter(of: rhs.action))
    if l != r {
        return l < r
    }
    return lhs.combo.describe() < rhs.combo.describe()
}

private func parameter(of action: HotkeyAction) -> Int {
    switch action {
    case .workspace(let number), .moveToWorkspace(let number), .moveColumnToWorkspace(let number): return number
    default: return 0
    }
}

/// Mac-style key symbols for a combo: modifiers in ⌃⌥⇧⌘ order, then the key.
public func keycaps(for combo: HotkeyCombo) -> [String] {
    let symbols: [(HotkeyModifier, String)] = [
        (.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘"),
    ]
    return symbols.filter { combo.modifiers.contains($0.0) }.map(\.1)
        + [keycapSymbols[combo.key] ?? combo.key]
}

/// Case-insensitive match over name, description, config name and the
/// combos (`alt+shift+h`). An empty query keeps everything.
public func filterShortcuts(_ entries: [ShortcutEntry], query: String) -> [ShortcutEntry] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else {
        return entries
    }
    return entries.filter { entry in
        let haystack = [entry.name, entry.summary, entry.configName ?? ""]
            + entry.bindings.map { $0.combo.describe() }
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}
