import Foundation

/// Plan §19 modifiers. Canonical display order follows macOS: ^⌥⇧⌘.
public enum HotkeyModifier: String, Hashable, Sendable, Equatable {
    case ctrl
    case alt
    case shift
    case cmd
}

/// A parsed key binding: modifiers plus one key. Pure value — knows nothing
/// about CGEvent or Carbon; the adapter builds these from OS events.
public struct HotkeyCombo: Hashable, Sendable, Equatable {
    public var modifiers: Set<HotkeyModifier>
    public var key: String

    public init(modifiers: Set<HotkeyModifier>, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Canonical rendering: `Alt+Shift+H`.
    public func describe() -> String {
        let ordered: [HotkeyModifier] = [.ctrl, .alt, .shift, .cmd]
        let mods = ordered.filter(modifiers.contains).map(\.rawValue.capitalized)
        return (mods + [key]).joined(separator: "+")
    }
}

private let modifierNames: [String: HotkeyModifier] = [
    "ctrl": .ctrl, "control": .ctrl,
    "alt": .alt, "option": .alt,
    "shift": .shift,
    "cmd": .cmd, "command": .cmd,
]

/// Why a hotkey text did not parse.
public enum HotkeyFailure: Error, Equatable, Sendable {
    /// Missing modifier, empty key or unknown modifier.
    case unparseable
    /// Modifiers were fine but the key is not in `supportedKeyNames`.
    case unknownKey(String)
}

/// Nil when `text` parses; otherwise the reason.
public func hotkeyFailure(_ text: String) -> HotkeyFailure? {
    switch parseHotkeyResult(text) {
    case .success:
        return nil
    case .failure(let failure):
        return failure
    }
}

/// Parse `"Alt+Shift+H"` (case-insensitive modifiers and key names). Nil for
/// empty text, empty key, unknown modifiers or a key outside the shared
/// vocabulary (`supportedKeyNames`), so a binding can never parse yet never fire.
public func parseHotkey(_ text: String) -> HotkeyCombo? {
    try? parseHotkeyResult(text).get()
}

private func parseHotkeyResult(_ text: String) -> Result<HotkeyCombo, HotkeyFailure> {
    let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let rawKey = parts.last, !rawKey.isEmpty else {
        return .failure(.unparseable)
    }
    var modifiers = Set<HotkeyModifier>()
    for name in parts.dropLast() {
        guard let modifier = modifierNames[name.lowercased()] else {
            return .failure(.unparseable)
        }
        modifiers.insert(modifier)
    }
    guard let key = canonicalKeyName(rawKey) else {
        return .failure(.unknownKey(rawKey))
    }
    return .success(HotkeyCombo(modifiers: modifiers, key: key))
}
