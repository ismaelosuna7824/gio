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
    /// Niri `move-column-left` (Alt+Shift+Comma, `<`; Alt+Shift+H until
    /// NC-14): swap the column with its neighbour.
    case moveColumnLeft
    /// Niri `move-column-right` (Alt+Shift+Period, `>`).
    case moveColumnRight
    /// `move-up` (Alt+Shift+K): the window trades places with the one above
    /// in its column; from the column's top, with Move Edge, to the display
    /// above (NC-14 `moveWindowOrToDisplay`).
    case moveUp
    /// `move-down` (Alt+Shift+J); see `moveUp`.
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
    /// Niri `consume-or-expel-window-left` (Alt+Shift+H and Alt+BracketLeft):
    /// NC-14 the OmniWM window move; from the workspace's left edge, with
    /// Move Edge, to the display on the left (`moveWindowOrToDisplay`).
    case consumeOrExpelLeft
    /// Niri `consume-or-expel-window-right` (Alt+Shift+L and Alt+BracketRight).
    case consumeOrExpelRight
    /// Niri `toggle-overview` (Alt+O): open or close the workspace overview.
    /// The app handles it (a panel); the session state is left unchanged.
    case toggleOverview
    /// Niri `focus-monitor-<direction>` (Ctrl+Alt+H/J/K/L): focus the
    /// neighbouring display (`displayNeighbour`) and its shown workspace.
    case focusMonitor(FocusDirection)
    /// Niri `move-column-to-monitor-<direction>` (Ctrl+Alt+Shift+H/J/K/L):
    /// the focused column moves to the neighbouring display's shown
    /// workspace and focus follows it.
    case moveColumnToMonitor(FocusDirection)
    /// Niri `move-window-to-monitor-<direction>` (unbound): only the focused
    /// window moves, as its own column; focus follows it.
    case moveWindowToMonitor(FocusDirection)
    /// Niri `move-workspace-to-monitor-<direction>` (unbound): the current
    /// workspace moves to the neighbouring display's stack; focus follows it.
    case moveWorkspaceToMonitor(FocusDirection)
    /// NC-08 niri `switch-preset-window-height` (Alt+Shift+R): cycle the
    /// focused window through `preset-window-heights` within its column.
    case switchPresetWindowHeight
    /// NC-08 niri `set-window-height "-10%"` (Alt+Shift+Minus).
    case shrinkWindowHeight
    /// NC-08 niri `set-window-height "+10%"` (Alt+Shift+Equal).
    case growWindowHeight
    /// NC-08 niri `reset-window-height` (Ctrl+Alt+R): every window of the
    /// focused column back to an equal share.
    case resetWindowHeight
    /// NC-09 niri `focus-column-first` (Alt+Home).
    case focusColumnFirst
    /// NC-09 niri `focus-column-last` (Alt+End).
    case focusColumnLast
    /// NC-09 niri `move-column-to-first` (Ctrl+Alt+Home).
    case moveColumnToFirst
    /// NC-09 niri `move-column-to-last` (Ctrl+Alt+End).
    case moveColumnToLast
    /// NC-09 niri `swap-window-left` (unbound): trade places with the left
    /// column's focused window.
    case swapWindowLeft
    /// NC-09 niri `swap-window-right` (unbound).
    case swapWindowRight
    /// NC-10 niri `move-column-to-workspace N` (Ctrl+Alt+N): the whole
    /// focused column; focus follows it.
    case moveColumnToWorkspace(Int)
    /// NC-10 niri `move-column-to-workspace-down` (Ctrl+Alt+U).
    case moveColumnToWorkspaceDown
    /// NC-10 niri `move-column-to-workspace-up` (Ctrl+Alt+I).
    case moveColumnToWorkspaceUp
    /// NC-11 niri `focus-workspace-previous` (unbound: Option+Tab belongs to
    /// app switchers such as AltTab): the display's previously shown workspace.
    case focusWorkspacePrevious
    /// NC-11 niri `move-workspace-down` (Ctrl+Alt+Shift+U): reorder the
    /// display's stack; named workspaces keep their config order.
    case moveWorkspaceDown
    /// NC-11 niri `move-workspace-up` (Ctrl+Alt+Shift+I).
    case moveWorkspaceUp
    /// NC-12 niri `focus-window-or-workspace-down` (unbound): the window
    /// below in the column, or the workspace below from its last window.
    case focusWindowOrWorkspaceDown
    /// NC-12 niri `focus-window-or-workspace-up` (unbound).
    case focusWindowOrWorkspaceUp
    /// NC-12 niri `switch-preset-column-width-back` (unbound: niri's
    /// Mod+Shift+R is Gio's window-height cycle): the presets in reverse.
    case switchPresetColumnWidthBack
    /// NC-12 niri `expand-column-to-available-width` (Ctrl+Alt+F): fill the
    /// width the other fully visible columns leave.
    case expandColumnToAvailableWidth
    /// NC-12 niri `center-visible-columns` (Ctrl+Alt+C).
    case centerVisibleColumns
    /// MM-06 niri `move-column-left-or-to-monitor-left` (unbound): move the
    /// column left; from the strip's left edge, to the display on the left,
    /// where it lands as the last column. Focus follows.
    case moveColumnLeftOrToMonitorLeft
    /// MM-06 niri `move-column-right-or-to-monitor-right` (unbound): lands as
    /// the first column of the display on the right.
    case moveColumnRightOrToMonitorRight
    /// MM-06 niri `focus-column-or-monitor-left` (unbound): the column on
    /// the left, or from the first column the display on the left.
    case focusColumnOrMonitorLeft
    /// MM-06 niri `focus-column-or-monitor-right` (unbound).
    case focusColumnOrMonitorRight
    /// DW-02 `toggle-workspace-layout` (Alt+Shift+T): the current workspace
    /// switches between the scrolling strip and the dwindle tree.
    case toggleWorkspaceLayout
    /// DW-02 `set-workspace-layout-scrolling` / `-dwindle` (unbound).
    case setWorkspaceLayout(WorkspaceLayoutKind)
    /// DW-02 `dwindle-toggle-split` (unbound): the focused window's split
    /// flips between side by side and stacked.
    case dwindleToggleSplit
    /// DW-02 `dwindle-swap-split` (unbound): its two halves trade places.
    case dwindleSwapSplit
    /// DW-02 `dwindle-balance` (Alt+Shift+B): every split back to half and half.
    case dwindleBalance
    /// DW-02 `dwindle-preselect-<direction>` (unbound): where the next
    /// window of the workspace opens next to the focused one.
    case dwindlePreselect(FocusDirection)
    /// DW-02 `dwindle-preselect-clear` (unbound).
    case dwindlePreselectClear
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

/// Plan defaults: Alt+HJKL focus, Alt+Shift+H/L move the window (NC-14: consume-or-expel, the OmniWM move;
/// the column move went to Alt+Shift+Comma/Period, `<` / `>`: Option+Shift+arrows select words in text
/// fields), Alt+Shift+J/K move the window down / up in its column, Alt+N workspace,
/// Alt+Shift+N move-to-workspace, Alt+U / Alt+I workspace down / up (Alt+Shift+U / I
/// move the window along), Alt+R cycle width presets,
/// Alt+Minus / Alt+Equal step the width by 10%, Alt+F maximize column, Alt+C center column, Alt+[ / Alt+] consume-or-expel, Alt+Shift+F fullscreen, Alt+Shift+Space toggle
/// floating, Alt+O the workspace overview, Ctrl+Alt+H/J/K/L focus the neighbouring display,
/// Ctrl+Alt+Shift+H/J/K/L move the column there and Ctrl+Alt+Cmd+H/J/K/L move only the focused
/// window (MM-04) (Alt+Space stays the launcher; exact-match combos never collide).
/// NC-08..NC-11 follow niri's defaults with Alt as Mod: Alt+Home/End focus the first/last column,
/// Ctrl+Alt+Home/End move the column there, Alt+Shift+Minus/Equal and Alt+Shift+R size the window
/// within its column, Ctrl+Alt+R resets the heights, Ctrl+Alt+N / Ctrl+Alt+U / I move the column to
/// a workspace, Ctrl+Alt+Shift+U / I move the workspace. `focus-workspace-previous` (niri Mod+Tab)
/// and `swap-window-*` ship unbound: Option+Tab is the AltTab switcher's default. NC-12:
/// Ctrl+Alt+F expands the column to the available width, Ctrl+Alt+C centers the visible columns
/// (niri Mod+Ctrl+F / C); `focus-window-or-workspace-*` (a commented alternative in niri) and
/// `switch-preset-column-width-back` (niri Mod+Shift+R, Gio's window-height cycle) ship unbound.
/// MM-06: `move-column-*-or-to-monitor-*` and `focus-column-or-monitor-*` ship unbound (niri's
/// default config binds none of them either). DW-02: Alt+Shift+T toggles the workspace layout
/// (Alt+Shift+Space, the first idea, is toggle-floating) and Alt+Shift+B balances the dwindle
/// splits (OmniWM's default); the other dwindle actions ship unbound, as in OmniWM.
public func defaultHotkeyBindings() -> [(HotkeyCombo, HotkeyAction)] {
    func combo(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyCombo {
        HotkeyCombo(modifiers: modifiers, key: key)
    }
    var bindings: [(HotkeyCombo, HotkeyAction)] = [
        (combo([.alt], "H"), .focusLeft),
        (combo([.alt], "L"), .focusRight),
        (combo([.alt], "K"), .focusUp),
        (combo([.alt], "J"), .focusDown),
        (combo([.alt, .shift], "H"), .consumeOrExpelLeft),
        (combo([.alt, .shift], "L"), .consumeOrExpelRight),
        (combo([.alt, .shift], "Comma"), .moveColumnLeft),
        (combo([.alt, .shift], "Period"), .moveColumnRight),
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
        (combo([.alt], "Home"), .focusColumnFirst),
        (combo([.alt], "End"), .focusColumnLast),
        (combo([.ctrl, .alt], "Home"), .moveColumnToFirst),
        (combo([.ctrl, .alt], "End"), .moveColumnToLast),
        (combo([.alt, .shift], "R"), .switchPresetWindowHeight),
        (combo([.alt, .shift], "Minus"), .shrinkWindowHeight),
        (combo([.alt, .shift], "Equal"), .growWindowHeight),
        (combo([.ctrl, .alt], "R"), .resetWindowHeight),
        (combo([.ctrl, .alt], "U"), .moveColumnToWorkspaceDown),
        (combo([.ctrl, .alt], "I"), .moveColumnToWorkspaceUp),
        (combo([.ctrl, .alt, .shift], "U"), .moveWorkspaceDown),
        (combo([.ctrl, .alt, .shift], "I"), .moveWorkspaceUp),
        (combo([.ctrl, .alt], "F"), .expandColumnToAvailableWidth),
        (combo([.ctrl, .alt], "C"), .centerVisibleColumns),
        (combo([.alt, .shift], "T"), .toggleWorkspaceLayout),
        (combo([.alt, .shift], "B"), .dwindleBalance),
    ]
    for number in 1...9 {
        bindings.append((combo([.alt], "\(number)"), .workspace(number)))
        bindings.append((combo([.alt, .shift], "\(number)"), .moveToWorkspace(number)))
        bindings.append((combo([.ctrl, .alt], "\(number)"), .moveColumnToWorkspace(number)))
    }
    let monitorKeys: [(String, FocusDirection)] = [("H", .left), ("J", .down), ("K", .up), ("L", .right)]
    for (key, direction) in monitorKeys {
        bindings.append((combo([.ctrl, .alt], key), .focusMonitor(direction)))
        bindings.append((combo([.ctrl, .alt, .shift], key), .moveColumnToMonitor(direction)))
        // MM-04: Command for "window" (niri leaves the window move as a
        // commented alternative on its column-move combo).
        bindings.append((combo([.ctrl, .alt, .cmd], key), .moveWindowToMonitor(direction)))
    }
    return bindings
}
