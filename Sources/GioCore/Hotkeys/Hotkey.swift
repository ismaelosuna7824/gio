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

/// Punctuation spellings folded into the canonical key names the OS tap
/// reports, so `"Alt+-"` and `"Alt+Minus"` bind the same key.
private let keyAliases: [String: String] = [
    "-": "Minus", "minus": "Minus",
    "=": "Equal", "equal": "Equal",
    "[": "BracketLeft", "bracketleft": "BracketLeft",
    "]": "BracketRight", "bracketright": "BracketRight",
]

/// Parse `"Alt+Shift+H"` (case-insensitive modifiers, single letters
/// uppercased). Nil for empty text, empty key, or unknown modifiers.
/// Multi-character keys (`"Space"`, `"F1"`) pass through untouched.
public func parseHotkey(_ text: String) -> HotkeyCombo? {
    let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let rawKey = parts.last, !rawKey.isEmpty else {
        return nil
    }
    var modifiers = Set<HotkeyModifier>()
    for name in parts.dropLast() {
        guard let modifier = modifierNames[name.lowercased()] else {
            return nil
        }
        modifiers.insert(modifier)
    }
    let key = keyAliases[rawKey.lowercased()] ?? (rawKey.count == 1 ? rawKey.uppercased() : rawKey)
    return HotkeyCombo(modifiers: modifiers, key: key)
}
