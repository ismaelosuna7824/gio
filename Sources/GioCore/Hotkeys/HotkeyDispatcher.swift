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
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case workspace(Int)
    case moveToWorkspace(Int)
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

/// Plan defaults: Alt+HJKL focus, Alt+Shift+HJKL move, Alt+N workspace,
/// Alt+Shift+N move-to-workspace, Alt+R cycle width presets,
/// Alt+Minus / Alt+Equal step the width by 10%, Alt+F maximize column, Alt+Shift+F fullscreen, Alt+Shift+Space toggle
/// floating (Alt+Space stays the launcher; exact-match combos never collide).
public func defaultHotkeyBindings() -> [(HotkeyCombo, HotkeyAction)] {
    func combo(_ modifiers: Set<HotkeyModifier>, _ key: String) -> HotkeyCombo {
        HotkeyCombo(modifiers: modifiers, key: key)
    }
    var bindings: [(HotkeyCombo, HotkeyAction)] = [
        (combo([.alt], "H"), .focusLeft),
        (combo([.alt], "L"), .focusRight),
        (combo([.alt], "K"), .focusUp),
        (combo([.alt], "J"), .focusDown),
        (combo([.alt, .shift], "H"), .moveLeft),
        (combo([.alt, .shift], "L"), .moveRight),
        (combo([.alt, .shift], "K"), .moveUp),
        (combo([.alt, .shift], "J"), .moveDown),
        (combo([.alt], "R"), .switchPresetColumnWidth),
        (combo([.alt], "Minus"), .shrinkColumnWidth),
        (combo([.alt], "Equal"), .growColumnWidth),
        (combo([.alt], "F"), .maximizeColumn),
        (combo([.alt, .shift], "F"), .fullscreen),
        (combo([.alt, .shift], "Space"), .toggleFloating),
    ]
    for number in 1...9 {
        bindings.append((combo([.alt], "\(number)"), .workspace(number)))
        bindings.append((combo([.alt, .shift], "\(number)"), .moveToWorkspace(number)))
    }
    return bindings
}
