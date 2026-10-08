import Foundation

/// DA-07: what a `[keybindings]` line points a combo at.
public enum KeybindingTarget: Equatable, Sendable {
    case action(HotkeyAction)
    /// `"none"`: the combo does nothing, a default binding included.
    case none
}

/// Alt+Space summons the launcher; the app handles it before the table and
/// the recorder refuses it.
public let launcherHotkey = HotkeyCombo(modifiers: [.alt], key: "Space")

// MARK: - Routing

/// Where a combo seen by the tap goes.
public enum HotkeyRoute: Equatable, Sendable {
    /// Not a Gio shortcut (or hotkeys are suspended): the key reaches apps.
    case passThrough
    case launcher
    /// `toggle-overview` is a panel the app shows.
    case overview
    case action(HotkeyAction)
}

/// The tap's decision. While `suspended` (a shortcut is being recorded)
/// every combo passes through, so the recorder sees it and nothing fires.
public func routeHotkey(_ combo: HotkeyCombo, dispatcher: HotkeyDispatcher, suspended: Bool) -> HotkeyRoute {
    if suspended {
        return .passThrough
    }
    if combo == launcherHotkey {
        return .launcher
    }
    guard let action = dispatcher.action(for: combo) else {
        return .passThrough
    }
    return action == .toggleOverview ? .overview : .action(action)
}

/// DA-07: the "hotkeys suspended" flag. Set from the main thread (the
/// recorder) and read in the tap callback (main), so the lock is only a
/// guard for other readers. Setting it twice is harmless.
public final class HotkeyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false

    public init() {}

    public var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    public func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        lock.unlock()
    }
}

// MARK: - Effective table

/// Defaults, minus `"none"` combos, with config bindings layered on top
/// (later wins, one action per combo), each marked by origin.
public func effectiveHotkeyBindings(
    configKeybindings: [(HotkeyCombo, HotkeyAction)], unbound: [HotkeyCombo] = []
) -> [HotkeyCombo: (action: HotkeyAction, source: ShortcutSource)] {
    var effective: [HotkeyCombo: (action: HotkeyAction, source: ShortcutSource)] = [:]
    for (combo, action) in defaultHotkeyBindings() {
        effective[combo] = (action, .default)
    }
    for combo in unbound {
        effective.removeValue(forKey: combo)
    }
    for (combo, action) in configKeybindings {
        effective[combo] = (action, .config)
    }
    return effective
}

private func defaultAction(for combo: HotkeyCombo) -> HotkeyAction? {
    defaultHotkeyBindings().last { $0.0 == combo }?.1
}

// MARK: - Validation

/// Why a recorded combo can never be bound.
public enum ShortcutProblem: Equatable, Sendable {
    case noModifier
    case unsupportedKey(String)
    case reservedForLauncher
}

/// What binding a recorded combo to an action would do.
public enum ShortcutCheck: Equatable, Sendable {
    /// Nothing runs on it: bind away.
    case free
    /// The action already runs on this combo.
    case alreadyBound
    /// Another action runs on it; binding takes it over (Replace).
    case conflict(action: HotkeyAction, source: ShortcutSource)
    case invalid(ShortcutProblem)
}

public func checkShortcut(_ combo: HotkeyCombo, for action: HotkeyAction, config: GioConfig) -> ShortcutCheck {
    if combo.modifiers.isEmpty {
        return .invalid(.noModifier)
    }
    guard canonicalKeyName(combo.key) == combo.key else {
        return .invalid(.unsupportedKey(combo.key))
    }
    if combo == launcherHotkey {
        return .invalid(.reservedForLauncher)
    }
    let effective = effectiveHotkeyBindings(configKeybindings: config.keybindings, unbound: config.unboundKeys)
    guard let current = effective[combo] else {
        return .free
    }
    if current.action == action {
        return .alreadyBound
    }
    return .conflict(action: current.action, source: current.source)
}

// MARK: - Edit lists

/// Add or Replace: the combo runs `action` from now on (whatever ran on it
/// before loses it, one action per combo).
public func addShortcutEdits(_ combo: HotkeyCombo, action: HotkeyAction) -> [ConfigEdit] {
    [.setKeybinding(combo, .action(action))]
}

/// Remove one binding. A combo with a default action is set to `"none"`
/// (deleting the line would bring the default back); a config-only combo
/// loses its line.
public func removeShortcutEdits(_ combo: HotkeyCombo) -> [ConfigEdit] {
    defaultAction(for: combo) == nil ? [.removeKeybinding(combo)] : [.setKeybinding(combo, .none)]
}

/// Every config line that changes what the family runs on: its own
/// bindings, `"none"` on its default combos, and its default combos bound
/// to other actions. Sorted for a stable edit list.
public func resetShortcutCombos(family: String, config: GioConfig) -> [HotkeyCombo] {
    let defaults = Set(defaultHotkeyBindings().filter { shortcutFamily(of: $0.1) == family }.map(\.0))
    var combos = Set(config.keybindings.filter { shortcutFamily(of: $0.1) == family }.map(\.0))
    combos.formUnion(config.unboundKeys.filter(defaults.contains))
    combos.formUnion(config.keybindings.map(\.0).filter(defaults.contains))
    return combos.sorted { $0.describe() < $1.describe() }
}

/// Reset to Default: drop those lines so the family's defaults run again.
public func resetShortcutEdits(family: String, config: GioConfig) -> [ConfigEdit] {
    resetShortcutCombos(family: family, config: config).map { .removeKeybinding($0) }
}
