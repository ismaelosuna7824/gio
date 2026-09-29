import Foundation

/// Reference grouping for the Shortcuts screen, in display order.
public enum ShortcutCategory: CaseIterable, Sendable {
    case focus, move, columns, windows, workspaces, app

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .move: return "Move"
        case .columns: return "Columns"
        case .windows: return "Windows"
        case .workspaces: return "Workspaces"
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
}

/// One row of the Shortcuts reference. Parameterized actions
/// (`workspace N`, `move-to-workspace N`) are one entry with several bindings.
public struct ShortcutEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let category: ShortcutCategory
    /// The spelling used in `config.toml`; nil for shortcuts the config cannot rebind.
    public let configName: String?
    public let bindings: [ShortcutBinding]
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
    case .moveLeft:
        return ActionInfo(id: "move-left", name: "Move column left", summary: "Move the focused window's column one place to the left.", category: .move)
    case .moveRight:
        return ActionInfo(id: "move-right", name: "Move column right", summary: "Move the focused window's column one place to the right.", category: .move)
    case .moveUp:
        return ActionInfo(id: "move-up", name: "Move window up", summary: "Move the focused window up within its column.", category: .move)
    case .moveDown:
        return ActionInfo(id: "move-down", name: "Move window down", summary: "Move the focused window down within its column.", category: .move)
    case .workspace:
        return ActionInfo(id: "workspace N", name: "Go to workspace N", summary: "Switch to workspace 1 to 9.", category: .workspaces)
    case .moveToWorkspace:
        return ActionInfo(id: "move-to-workspace N", name: "Move window to workspace N", summary: "Send the focused window to workspace 1 to 9.", category: .workspaces)
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
    }
}

/// Stable id of the entry an action belongs to (`workspace(3)` and
/// `workspace(5)` share one).
public func shortcutFamily(of action: HotkeyAction) -> String {
    actionInfo(action).id
}

/// One representative per family, in display order within each category.
private let catalogActions: [HotkeyAction] = [
    .focusLeft, .focusRight, .focusUp, .focusDown,
    .moveLeft, .moveRight, .moveUp, .moveDown,
    .switchPresetColumnWidth, .shrinkColumnWidth, .growColumnWidth,
    .maximizeColumn, .centerColumn, .consumeOrExpelLeft, .consumeOrExpelRight,
    .toggleFloating, .fullscreen,
    .workspace(1), .moveToWorkspace(1),
]

/// Alt+Space is handled by the app before the action table.
private let launcherCombo = HotkeyCombo(modifiers: [.alt], key: "Space")

/// Effective bindings: defaults with config bindings layered on top (later
/// wins, one action per combo), grouped by action, each marked by origin.
public func shortcutCatalog(
    configKeybindings: [(HotkeyCombo, HotkeyAction)]
) -> [ShortcutEntry] {
    var effective: [HotkeyCombo: (action: HotkeyAction, source: ShortcutSource)] = [:]
    for (combo, action) in defaultHotkeyBindings() {
        effective[combo] = (action, .default)
    }
    for (combo, action) in configKeybindings {
        effective[combo] = (action, .config)
    }
    var byFamily: [String: [(combo: HotkeyCombo, action: HotkeyAction, source: ShortcutSource)]] = [:]
    for (combo, value) in effective {
        byFamily[shortcutFamily(of: value.action), default: []]
            .append((combo, value.action, value.source))
    }
    var entries: [ShortcutEntry] = catalogActions.map { representative in
        let info = actionInfo(representative)
        let bindings = (byFamily[info.id] ?? []).sorted { lhs, rhs in
            let (l, r) = (parameter(of: lhs.action), parameter(of: rhs.action))
            if l != r {
                return l < r
            }
            return lhs.combo.describe() < rhs.combo.describe()
        }.map { ShortcutBinding(combo: $0.combo, source: $0.source) }
        return ShortcutEntry(
            id: info.id, name: info.name, summary: info.summary,
            category: info.category, configName: info.id, bindings: bindings
        )
    }
    entries.append(ShortcutEntry(
        id: "launcher", name: "Open launcher",
        summary: "Summon the launcher panel to search and open apps and windows.",
        category: .app, configName: nil,
        bindings: [ShortcutBinding(combo: launcherCombo, source: .default)]
    ))
    return entries
}

private func parameter(of action: HotkeyAction) -> Int {
    switch action {
    case .workspace(let number), .moveToWorkspace(let number): return number
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
