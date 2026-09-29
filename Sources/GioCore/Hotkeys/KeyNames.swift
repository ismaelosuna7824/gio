import Foundation

/// HD-03: the single key-name vocabulary. `parseHotkey` accepts exactly these
/// canonical names (plus the aliases below); the macOS tap keys its keycode
/// table by them, and a test keeps both sides identical.
public let supportedKeyNames: [String] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
    + "0123456789".map(String.init)
    + (1...12).map { "F\($0)" }
    + ["Left", "Right", "Up", "Down", "Tab", "Return", "Escape", "Space", "Delete"]
    + ["Grave", "Comma", "Period", "Slash", "Semicolon", "Quote", "Backslash",
       "Minus", "Equal", "BracketLeft", "BracketRight"]
    + ["Home", "End", "PageUp", "PageDown"]

/// Symbol and word spellings folded into canonical names, keyed lowercase.
private let keyAliases: [String: String] = [
    "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight",
    ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash",
    "\\": "Backslash", "`": "Grave",
    "esc": "Escape", "enter": "Return", "backspace": "Delete",
    "pgup": "PageUp", "pgdn": "PageDown",
]

private let canonicalByLowercase: [String: String] = {
    var table = keyAliases
    for name in supportedKeyNames {
        table[name.lowercased()] = name
    }
    return table
}()

/// The canonical name for a user-typed key (case-insensitive), or nil when the
/// key is not in the vocabulary.
public func canonicalKeyName(_ raw: String) -> String? {
    canonicalByLowercase[raw.lowercased()]
}

/// Keycap glyphs for keys whose canonical name is not what a keyboard shows.
public let keycapSymbols: [String: String] = [
    "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]",
    "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/",
    "Backslash": "\\", "Grave": "`",
    "Left": "←", "Right": "→", "Up": "↑", "Down": "↓",
    "Tab": "⇥", "Return": "⏎", "Escape": "⎋", "Delete": "⌫",
]
