import GioCore
import SwiftUI

/// DD-04 Shortcuts: every action with its live keys. Search (⌘F), category
/// chips, cards per category, and a compact cheat-sheet grid.
struct ShortcutsView: View {
    @ObservedObject var model: DesktopModel
    @State private var query: String
    @State private var chip: ShortcutChip
    @State private var cheatSheet: Bool
    @FocusState private var searchFocused: Bool

    /// The seeds are for snapshot tests.
    init(model: DesktopModel, query: String = "", chip: ShortcutChip = .all, cheatSheet: Bool = false) {
        self.model = model
        _query = State(initialValue: query)
        _chip = State(initialValue: chip)
        _cheatSheet = State(initialValue: cheatSheet)
    }

    var body: some View {
        let catalog = shortcutCatalog(configKeybindings: model.snapshot.keybindings)
        let sections = shortcutSections(catalog, chip: chip, query: query)
        GioPage(
            "Shortcuts",
            subtitle: "Every action and the keys that run it. Rebind any of them in config.toml."
        ) {
            GioSegmented(
                title: "Layout", selection: $cheatSheet,
                options: [(false, "List"), (true, "Cheat Sheet")], width: 190
            )
        } content: {
            VStack(alignment: .leading, spacing: GioSpacing.s) {
                GioSearchField(
                    prompt: "Search actions, keys or config names", text: $query, hint: "⌘F", focus: $searchFocused
                )
                chips(catalog)
            }
            if sections.isEmpty {
                SectionCard {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "No shortcuts match \u{201C}\(query)\u{201D}",
                        message: chip == .all
                            ? "Try an action name like \u{201C}focus\u{201D}, a key like \u{201C}alt+h\u{201D} or a config name."
                            : "Nothing in \(chip.title) matches. Search every category instead?"
                    ) {
                        HStack(spacing: GioSpacing.xs) {
                            if chip != .all {
                                GioButton(title: "Search All") { chip = .all }
                            }
                            GioButton(title: "Clear Search") { query = "" }
                        }
                    }
                }
            } else if cheatSheet {
                ForEach(sections) { CheatSheetSection(section: $0) }
            } else {
                ForEach(sections) { section in
                    SectionCard(section.category.title) {
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            CardRow(divider: index < section.entries.count - 1) {
                                ShortcutRow(entry: entry)
                            }
                        }
                    }
                }
            }
        }
        .background {
            // ⌘F focuses search from anywhere on the page.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear { model.refresh() }
        .pollWhileVisible(model, every: 3) { model.refresh() }
    }

    private func chips(_ catalog: [ShortcutEntry]) -> some View {
        HStack(spacing: GioSpacing.xs - 2) {
            ForEach(ShortcutChip.allChips, id: \.self) { candidate in
                FilterChip(
                    title: candidate.title, count: shortcutChipCount(catalog, chip: candidate, query: query),
                    isSelected: candidate == chip
                ) { chip = candidate }
            }
        }
    }
}

/// Name and one-line description on the left, keycaps on the right.
private struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        HStack(alignment: .center, spacing: GioSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GioSpacing.xs - 2) {
                    Text(entry.name).font(GioFont.body.weight(.medium))
                    if isOverridden(entry) {
                        InlineTag(text: "config", tint: GioColor.warning, ink: GioColor.ink(.systemOrange))
                            .help("Bound in config.toml")
                    }
                }
                Text(entry.summary)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BindingKeys(bindings: entry.bindings)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The keycaps of an action: every combo, a range for long families,
/// "Unbound" when nothing runs it.
private struct BindingKeys: View {
    let bindings: [ShortcutBinding]
    var compactRange = true

    var body: some View {
        let compact = compactBindings(bindings)
        if bindings.isEmpty {
            Text("Unbound")
                .font(GioFont.caption)
                .foregroundStyle(GioColor.tertiaryText)
        } else {
            HStack(spacing: GioSpacing.xs) {
                ForEach(Array(compact.shown.enumerated()), id: \.offset) { index, binding in
                    if index > 0 {
                        Text(compact.isRange ? "…" : "or")
                            .font(GioFont.caption)
                            .foregroundStyle(GioColor.tertiaryText)
                    }
                    KeyCombo(binding.combo)
                }
            }
            .fixedSize()
        }
    }
}

/// Cheat sheet: small tiles in a grid, keys first for quick scanning.
private struct CheatSheetSection: View {
    let section: ShortcutSection
    private let columns = [GridItem(.flexible(), spacing: GioSpacing.s), GridItem(.flexible(), spacing: GioSpacing.s), GridItem(.flexible(), spacing: GioSpacing.s)]

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xs) {
            Text(section.category.title)
                .font(GioFont.sectionTitle)
                .padding(.horizontal, GioSpacing.xxs)
            LazyVGrid(columns: columns, alignment: .leading, spacing: GioSpacing.s) {
                ForEach(section.entries) { entry in
                    VStack(alignment: .leading, spacing: GioSpacing.xs - 2) {
                        BindingKeys(bindings: entry.bindings)
                        HStack(spacing: GioSpacing.xxs) {
                            Text(entry.name)
                                .font(GioFont.caption.weight(.medium))
                                .foregroundStyle(GioColor.secondaryText)
                                .lineLimit(1)
                            if isOverridden(entry) {
                                Circle().fill(GioColor.warning).frame(width: 5, height: 5)
                                    .help("Bound in config.toml")
                            }
                        }
                    }
                    .padding(GioSpacing.s - 2)
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                            .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
                    )
                    .help(entry.summary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
