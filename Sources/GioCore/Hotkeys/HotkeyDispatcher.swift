import Foundation

/// Plan §19 actions. The hotkey layer converts events into these and stops:
/// all behavior lives in Core use cases (focus/move/registry/manager).
/// Resize-mode steps are bound later (Phase 14 config); the mode itself is
/// a hotkey-layer concern, not new action cases.
public enum HotkeyAction: Equatable, Sendable {
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    /// Legacy `move-window-left` (config `move-left` still parses): appends the
    /// window to the neighbouring column. Unbound by default since FI-06.
    case moveLeft
    /// Legacy `move-window-right`; see `moveLeft`.
    case moveRight
    /// Niri `move-column-left` (Alt+Shift+H): swap the column with its neighbour.
    case moveColumnLeft
    /// Niri `move-column-right` (Alt+Shift+L).
    case moveColumnRight
    case moveUp
    case moveDown
    case workspace(Int)
    case moveToWorkspace(Int)
    /// Niri `focus-workspace-down` (Alt+U): the workspace below in the stack.
    case focusWorkspaceDown
    /// Niri `focus-workspace-up` (Alt+I).
    case focusWorkspaceUp
    /// Niri `move-window-to-workspace-down` (Alt+Shift+U): the window follows.
    case moveWindowToWorkspaceDown
    /// Niri `move-window-to-workspace-up` (Alt+Shift+I).
    case moveWindowToWorkspaceUp
    case toggleFloating
    case fullscreen
    /// Niri `switch-preset-column-width` (Alt+R).
    case switchPresetColumnWidth
    /// Niri `set-column-width "-10%"` (Alt+Minus).
    case shrinkColumnWidth
    /// Niri `set-column-width "+10%"` (Alt+Equal).
    case growColumnWidth
    /// Niri `maximize-column` (Alt+F).
    case maximizeColumn
    /// Niri `center-column` (Alt+C).
    case centerColumn
    /// Niri `consume-or-expel-window-left` (Alt+BracketLeft).
    case consumeOrExpelLeft
    /// Niri `consume-or-expel-window-right` (Alt+BracketRight).
    case consumeOrExpelRight
    /// Niri `toggle-overview` (Alt+O): open or close the workspace overview.
    /// The app handles it (a panel); the session state is left unchanged.
    case toggleOverview
}

/// The binding table. Later entries override earlier ones on collision, so
/// user config layers cleanly over defaults.
public struct HotkeyDispatcher: Equatable, Sendable {
    private var bindings: [HotkeyCombo: HotkeyAction]

    public init(bindings: [(HotkeyCombo, HotkeyAction)] = defaultHotkeyBindings()) {
        var table: [HotkeyCombo: HotkeyAction] = [:]
        for (combo, action) in bindings {
            table[combo] = action
        }
        self.bindings = table
    }

    public func action(for combo: HotkeyCombo) -> HotkeyAction? {
        bindings[combo]
    }

    public mutating func bind(_ action: HotkeyAction, to combo: HotkeyCombo) {
        bindings[combo] = action
    }

    public mutating func unbind(_ combo: HotkeyCombo) {
        bindings.removeValue(forKey: combo)
    }

    public var bindingCount: Int {
        bindings.count
    }
}

/// Plan defaults: Alt+HJKL focus, Alt+Shift+H/L move the column, Alt+Shift+J/K move the window down / up in its column, Alt+N workspace,
/// Alt+Shift+N move-to-workspace, Alt+U / Alt+I workspace down / up (Alt+Shift+U / I
/// move the window along), Alt+R cycle width presets,
/// Alt+Minus / Alt+Equal step the width by 10%, Alt+F maximize column, Alt+C center column, Alt+[ / Alt+] consume-or-expel, Alt+Shift+F fullscreen, Alt+Shift+Space toggle
/// floating, Alt+O the workspace overview (Alt+Space stays the launcher; exact-match combos never collide).
public func defaultHotkeyBindings() -> [(HotkeyCombo, HotkeyAction)] {
    func combo(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyCombo {
        HotkeyCombo(modifiers: modifiers, key: key)
    }
    var bindings: [(HotkeyCombo, HotkeyAction)] = [
        (combo([.alt], "H"), .focusLeft),
        (combo([.alt], "L"), .focusRight),
        (combo([.alt], "K"), .focusUp),
        (combo([.alt], "J"), .focusDown),
        (combo([.alt, .shift], "H"), .moveColumnLeft),
        (combo([.alt, .shift], "L"), .moveColumnRight),
        (combo([.alt, .shift], "K"), .moveUp),
        (combo([.alt, .shift], "J"), .moveDown),
        (combo([.alt], "R"), .switchPresetColumnWidth),
        (combo([.alt], "Minus"), .shrinkColumnWidth),
        (combo([.alt], "Equal"), .growColumnWidth),
        (combo([.alt], "F"), .maximizeColumn),
        (combo([.alt, .shift], "F"), .fullscreen),
        (combo([.alt], "C"), .centerColumn),
        (combo([.alt], "BracketLeft"), .consumeOrExpelLeft),
        (combo([.alt], "BracketRight"), .consumeOrExpelRight),
        (combo([.alt, .shift], "Space"), .toggleFloating),
        (combo([.alt], "U"), .focusWorkspaceDown),
        (combo([.alt], "I"), .focusWorkspaceUp),
        (combo([.alt, .shift], "U"), .moveWindowToWorkspaceDown),
        (combo([.alt, .shift], "I"), .moveWindowToWorkspaceUp),
        (combo([.alt], "O"), .toggleOverview),
    ]
    for number in 1...9 {
        bindings.append((combo([.alt], "\(number)"), .workspace(number)))
        bindings.append((combo([.alt, .shift], "\(number)"), .moveToWorkspace(number)))
    }
    return bindings
}
