import Foundation
import GioCore

/// DA-07 pure presentation for editing Shortcuts and the Logs "Log file
/// level" picker. The rules and edit lists live in GioCore
/// (`KeybindingEditing.swift`); this file only words and groups them.

// MARK: - Rows

/// One combo in an editable row.
public struct ShortcutBindingItem: Equatable, Sendable, Identifiable {
    public let combo: HotkeyCombo
    public let source: ShortcutSource
    /// Tooltip: the keys and where the binding comes from.
    public let help: String
    public var id: String { combo.describe() }
}

/// What a Shortcuts row shows and allows.
public struct ShortcutRowModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let bindings: [ShortcutBindingItem]
    /// Defaults switched off with `"none"`, shown struck through.
    public let removed: [HotkeyCombo]
    /// config.toml changes this action (the "config" tag).
    public let isCustomized: Bool
    public let canReset: Bool
    /// Workspace families pick the number in the recorder; empty otherwise.
    public let workspaceChoices: [Int]
    /// Long families read first…last; their removals live in the row menu.
    public let isRange: Bool
    public let resetEdits: [ConfigEdit]

    /// Remove one binding (a default becomes `"none"`).
    public func removeEdits(_ combo: HotkeyCombo) -> [ConfigEdit] {
        removeShortcutEdits(combo)
    }
}

public func shortcutRowModel(_ entry: ShortcutEntry, config: GioConfig) -> ShortcutRowModel {
    let reset = resetShortcutEdits(family: entry.id, config: config)
    let items = entry.bindings.map { binding in
        ShortcutBindingItem(
            combo: binding.combo, source: binding.source,
            help: "\(keycapText(binding.combo)) · \(sourceText(binding.source))"
        )
    }
    return ShortcutRowModel(
        id: entry.id, name: entry.name, summary: entry.summary,
        bindings: items, removed: entry.removedDefaults,
        isCustomized: !reset.isEmpty, canReset: !reset.isEmpty,
        workspaceChoices: workspaceNumber(entry.action) == nil ? [] : Array(1...9),
        isRange: compactBindings(entry.bindings).isRange,
        resetEdits: reset
    )
}

/// `⌥⇧H`: the combo as one string of keycap glyphs.
public func keycapText(_ combo: HotkeyCombo) -> String {
    keycaps(for: combo).joined()
}

private func sourceText(_ source: ShortcutSource) -> String {
    switch source {
    case .default: return "default"
    case .config: return "set in config.toml"
    }
}

/// The workspace number of a parameterized action, nil for the rest.
private func workspaceNumber(_ action: HotkeyAction) -> Int? {
    switch action {
    case .workspace(let number), .moveToWorkspace(let number), .moveColumnToWorkspace(let number): return number
    default: return nil
    }
}

private func withWorkspace(_ action: HotkeyAction, _ number: Int) -> HotkeyAction {
    switch action {
    case .workspace: return .workspace(number)
    case .moveToWorkspace: return .moveToWorkspace(number)
    case .moveColumnToWorkspace: return .moveColumnToWorkspace(number)
    default: return action
    }
}

// MARK: - Recorder

/// A key pressed while recording.
public enum RecorderKey: Equatable, Sendable {
    case cancel
    case capture(HotkeyCombo)
}

/// A bare Escape cancels; Escape with modifiers is a combo like any other.
public func recorderKey(_ combo: HotkeyCombo) -> RecorderKey {
    combo.modifiers.isEmpty && combo.key == "Escape" ? .cancel : .capture(combo)
}

/// The Add Shortcut sheet: the action, the captured combo and the verdict.
public struct ShortcutRecorder: Equatable, Sendable {
    public let entryName: String
    public private(set) var action: HotkeyAction
    public private(set) var combo: HotkeyCombo?
    public private(set) var check: ShortcutCheck?
    public let workspaceChoices: [Int]

    public init(entry: ShortcutEntry) {
        entryName = entry.name
        action = entry.action
        workspaceChoices = workspaceNumber(entry.action) == nil ? [] : Array(1...9)
    }

    public var workspace: Int? {
        workspaceNumber(action)
    }

    public mutating func choose(workspace number: Int, config: GioConfig) {
        action = withWorkspace(action, number)
        if let combo {
            check = checkShortcut(combo, for: action, config: config)
        }
    }

    public mutating func record(_ combo: HotkeyCombo, config: GioConfig) {
        self.combo = combo
        check = checkShortcut(combo, for: action, config: config)
    }

    public var message: String {
        guard let combo, let check else {
            return "Press the new shortcut. Esc cancels."
        }
        let keys = keycapText(combo)
        let target = shortcutActionTitle(action)
        switch check {
        case .free:
            return "\(keys) is free."
        case .alreadyBound:
            return "\(keys) already runs \(target)."
        case .conflict(let other, let source):
            return "\(keys) already runs \(shortcutActionTitle(other)) (\(sourceText(source))). Replace moves it to \(target)."
        case .invalid(.noModifier):
            return "Add at least one modifier (⌃ ⌥ ⇧ ⌘) so the key still types normally."
        case .invalid(.unsupportedKey(let key)):
            return "\(key) cannot be bound. Use a letter, digit, F1–F12, an arrow or a punctuation key."
        }
    }

    public var tone: StatusKind {
        switch check {
        case nil, .alreadyBound?: return .info
        case .free?: return .ok
        case .conflict?: return .warning
        case .invalid?: return .error
        }
    }

    /// The confirm button: "Add" for a free combo, "Replace" for a taken one.
    public var saveTitle: String? {
        switch check {
        case .free?: return "Add"
        case .conflict?: return "Replace"
        default: return nil
        }
    }

    public var edits: [ConfigEdit] {
        guard saveTitle != nil, let combo else {
            return []
        }
        return addShortcutEdits(combo, action: action)
    }

    /// The toast after a successful save.
    public var savedTitle: String {
        guard let combo else {
            return "Applied"
        }
        return "\(saveTitle == "Replace" ? "Moved" : "Added") \(keycapText(combo)) to \(shortcutActionTitle(action))"
    }
}

// MARK: - Log file level

public struct LogFileLevelOption: Equatable, Sendable, Hashable {
    public let level: LogLevel
    public let title: String
}

/// The picker's choices, most verbose first.
public let logFileLevelOptions: [LogFileLevelOption] = LogLevel.allCases.map {
    LogFileLevelOption(level: $0, title: logLevelTitle($0))
}

/// `[logging] level` edits; empty when nothing changes.
public func logFileLevelEdits(current: LogLevel, chosen: LogLevel) -> [ConfigEdit] {
    current == chosen ? [] : logLevelEdits(chosen)
}

public func logFileLevelToast(_ feedback: ApplyFeedback, level: LogLevel) -> ApplyToast {
    ApplyToast(feedback: feedback, successTitle: "gio.log now records \(logLevelTitle(level)) and above")
}
