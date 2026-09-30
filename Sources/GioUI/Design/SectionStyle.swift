import GioCore

/// Tile colors for sidebar sections, System Settings style. Named, not
/// SwiftUI colors, so the table stays pure and testable.
public enum SectionTint: String, CaseIterable, Sendable {
    case blue, indigo, purple, pink, orange, green, gray, teal, cyan
}

public struct SectionStyle: Equatable, Sendable {
    public let symbol: String
    public let tint: SectionTint
}

/// Symbol (filled, drawn white in a colored tile) and tint per section.
public func sectionStyle(_ section: MainSection) -> SectionStyle {
    switch section {
    case .overview: return SectionStyle(symbol: "square.grid.2x2.fill", tint: .blue)
    case .shortcuts: return SectionStyle(symbol: "command", tint: .gray)
    case .workspaces: return SectionStyle(symbol: "square.stack.3d.up.fill", tint: .cyan)
    case .layout: return SectionStyle(symbol: "rectangle.split.3x1.fill", tint: .indigo)
    case .focus: return SectionStyle(symbol: "viewfinder", tint: .purple)
    case .animations: return SectionStyle(symbol: "wand.and.stars", tint: .pink)
    case .rules: return SectionStyle(symbol: "checklist", tint: .orange)
    case .logs: return SectionStyle(symbol: "doc.text.fill", tint: .teal)
    case .diagnostics: return SectionStyle(symbol: "stethoscope", tint: .green)
    }
}

/// One titled group of sidebar rows.
public struct SidebarGroup: Equatable, Sendable, Identifiable {
    public let title: String
    public let sections: [MainSection]
    public var id: String { title }
}

/// Sidebar grouping, top to bottom. Covers every section exactly once.
public let sidebarGroups: [SidebarGroup] = [
    SidebarGroup(title: "General", sections: [.overview]),
    SidebarGroup(title: "Keyboard", sections: [.shortcuts]),
    SidebarGroup(title: "Tiling", sections: [.workspaces, .layout, .focus, .animations, .rules]),
    SidebarGroup(title: "Advanced", sections: [.logs, .diagnostics]),
]

// MARK: - Keycaps

/// How a keycap is drawn: square modifier/single glyph, or a wider cap for
/// named keys (`Space`, `F12`).
public enum KeycapRole: Equatable, Sendable {
    case modifier, key, wideKey
}

public struct KeycapGlyph: Equatable, Sendable {
    public let text: String
    public let role: KeycapRole
}

public func modifierGlyph(_ modifier: HotkeyModifier) -> String {
    switch modifier {
    case .ctrl: return "⌃"
    case .alt: return "⌥"
    case .shift: return "⇧"
    case .cmd: return "⌘"
    }
}

/// Keycaps for a combo: modifiers in macOS order (⌃⌥⇧⌘), then the key glyph.
public func keycapGlyphs(for combo: HotkeyCombo) -> [KeycapGlyph] {
    let order: [HotkeyModifier] = [.ctrl, .alt, .shift, .cmd]
    let modifiers = order.filter(combo.modifiers.contains).map {
        KeycapGlyph(text: modifierGlyph($0), role: .modifier)
    }
    let text = keycapSymbols[combo.key] ?? (combo.key.count == 1 ? combo.key.uppercased() : combo.key)
    return modifiers + [KeycapGlyph(text: text, role: text.count > 1 ? .wideKey : .key)]
}
