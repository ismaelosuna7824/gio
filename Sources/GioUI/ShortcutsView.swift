import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// DD-04 Shortcuts: every action with its live keys. Search (⌘F), category
/// chips, cards per category, and a compact cheat-sheet grid. DA-07: each
/// row adds (recorder sheet), removes (×) and resets its shortcuts; every
/// change is one config edit applied right away with a toast, like Rules.
struct ShortcutsView: View {
    @ObservedObject var model: DesktopModel
    @State private var query: String
    @State private var chip: ShortcutChip
    @State private var cheatSheet: Bool
    @State private var recording: RecordingTarget?
    @State private var toast: ApplyToast?
    @FocusState private var searchFocused: Bool

    /// The seeds are for snapshot tests.
    init(
        model: DesktopModel, query: String = "", chip: ShortcutChip = .all, cheatSheet: Bool = false,
        toast: ApplyToast? = nil
    ) {
        self.model = model
        _query = State(initialValue: query)
        _chip = State(initialValue: chip)
        _cheatSheet = State(initialValue: cheatSheet)
        _toast = State(initialValue: toast)
    }

    var body: some View {
        let config = model.snapshot.config
        let catalog = shortcutCatalog(configKeybindings: config.keybindings, unbound: config.unboundKeys)
        let sections = shortcutSections(catalog, chip: chip, query: query)
        GioPage(
            "Shortcuts",
            subtitle: "Every action and the keys that run it. Add, remove or reset shortcuts here; changes apply right away."
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
                ForEach(sections) { CheatSheetSection(section: $0, config: config) }
            } else {
                ForEach(sections) { section in
                    SectionCard(section.category.title) {
                        ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                            CardRow(divider: index < section.entries.count - 1) {
                                ShortcutRow(
                                    row: shortcutRowModel(entry, config: config),
                                    onAdd: { recording = ShortcutRecorder(entry: entry).map(RecordingTarget.init) },
                                    onRemove: { remove($0, from: entry, config: config) },
                                    onReset: { reset(entry, config: config) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .applyToastOverlay($toast)
        .background {
            // ⌘F focuses search from anywhere on the page.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(item: $recording) { target in
            ShortcutRecorderSheet(model: model, recorder: target.recorder) { saved in
                model.resumeHotkeys()
                toast = ApplyToast(feedback: model.apply(saved.edits), successTitle: saved.savedTitle)
                recording = nil
            } onCancel: {
                model.resumeHotkeys()
                recording = nil
            }
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

    private func remove(_ combo: HotkeyCombo, from entry: ShortcutEntry, config: GioConfig) {
        let row = shortcutRowModel(entry, config: config)
        toast = ApplyToast(
            feedback: model.apply(row.removeEdits(combo)),
            successTitle: "Removed \(keycapText(combo)) from \(entry.name)"
        )
    }

    private func reset(_ entry: ShortcutEntry, config: GioConfig) {
        let row = shortcutRowModel(entry, config: config)
        toast = ApplyToast(
            feedback: model.apply(row.resetEdits), successTitle: "\(entry.name) is back to its default shortcuts"
        )
    }
}

/// The sheet's item: one recorder per Add Shortcut press.
private struct RecordingTarget: Identifiable {
    let id = UUID()
    let recorder: ShortcutRecorder
}

/// Name and one-line description on the left; keycaps with ×, Add and
/// Reset on the right.
private struct ShortcutRow: View {
    let row: ShortcutRowModel
    let onAdd: () -> Void
    let onRemove: (HotkeyCombo) -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: GioSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GioSpacing.xs - 2) {
                    Text(row.name).font(GioFont.body.weight(.medium))
                    if row.isCustomized {
                        InlineTag(text: "config", tint: GioColor.warning, ink: GioColor.ink(.systemOrange))
                            .help("Changed from the default (stored in config.toml)")
                    }
                }
                Text(row.summary)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.summary)
                if !row.removed.isEmpty {
                    Text("Removed: " + row.removed.map(keycapText).joined(separator: ", "))
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.tertiaryText)
                        .help("Default shortcuts switched off (\"none\" in config.toml). Reset to Default brings them back.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            keys
            if row.isEditable {
                actions
            } else {
                Text("Fixed")
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.tertiaryText)
                    .frame(width: 118, alignment: .leading)
                    .help("Alt+Space always opens the launcher")
            }
        }
    }

    @ViewBuilder
    private var keys: some View {
        if row.bindings.isEmpty {
            Text("Unbound")
                .font(GioFont.caption)
                .foregroundStyle(GioColor.tertiaryText)
        } else if !row.isEditable {
            BindingKeys(bindings: row.bindings.map { ShortcutBinding(combo: $0.combo, source: $0.source) })
        } else if row.isRange {
            // A long family reads first…last; its removals live in a menu.
            HStack(spacing: GioSpacing.xs) {
                BindingKeys(bindings: row.bindings.map { ShortcutBinding(combo: $0.combo, source: $0.source) })
                GioIconMenu("Remove a shortcut", systemImage: "minus.circle") {
                    ForEach(row.bindings) { item in
                        Button("Remove \(keycapText(item.combo))") { onRemove(item.combo) }
                    }
                }
            }
            .fixedSize()
        } else {
            HStack(spacing: GioSpacing.xs) {
                ForEach(row.bindings) { item in
                    RemovableKeys(item: item) { onRemove(item.combo) }
                }
            }
            .fixedSize()
        }
    }

    /// Fixed width so the keycaps line up whether or not Reset shows.
    private var actions: some View {
        HStack(spacing: GioSpacing.xs) {
            GioButton(title: "Add", systemImage: "plus", role: .borderless, action: onAdd)
                .help("Add Shortcut: record a new key combination for \(row.name)")
            if row.canReset {
                GioButton(title: "Reset", systemImage: "arrow.uturn.backward", role: .borderless, action: onReset)
                    .help("Reset to Default: drop this action's lines from config.toml")
            }
        }
        .fixedSize()
        .frame(width: 118, alignment: .leading)
    }
}

/// One combo with its remove button.
private struct RemovableKeys: View {
    let item: ShortcutBindingItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            KeyCombo(item.combo)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(GioColor.tertiaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(keycapText(item.combo))")
            .accessibilityLabel("Remove \(item.combo.describe())")
        }
        .help(item.help)
    }
}

/// The keycaps of an action: every combo, a range for long families,
/// "Unbound" when nothing runs it.
private struct BindingKeys: View {
    let bindings: [ShortcutBinding]

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
    let config: GioConfig
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
                            if shortcutRowModel(entry, config: config).isCustomized {
                                Circle().fill(GioColor.warning).frame(width: 5, height: 5)
                                    .help("Changed from the default (stored in config.toml)")
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

// MARK: - Recorder

/// DA-07 Add Shortcut: captures the next key combo with a local key monitor
/// while Gio's global hotkeys are suspended (a bound combo would otherwise
/// run its action instead of reaching this sheet). Esc cancels; hotkeys
/// resume on save, cancel, sheet close, app switch and window close.
struct ShortcutRecorderSheet: View {
    @ObservedObject var model: DesktopModel
    @State private var recorder: ShortcutRecorder
    @State private var monitor = KeyMonitorBox()
    let onSave: (ShortcutRecorder) -> Void
    let onCancel: () -> Void
    @Environment(\.gioStaticPage) private var isStatic

    init(
        model: DesktopModel, recorder: ShortcutRecorder,
        onSave: @escaping (ShortcutRecorder) -> Void, onCancel: @escaping () -> Void
    ) {
        self.model = model
        _recorder = State(initialValue: recorder)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Shortcut").font(.system(size: 15, weight: .semibold))
                Text("For \u{201C}\(recorder.entryName)\u{201D}. Gio's shortcuts are paused while this is open.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recorder.workspaceChoices.isEmpty {
                SectionCard {
                    CardRow(divider: false) {
                        SettingRow("Workspace", caption: "Which workspace the shortcut targets.") {
                            GioPopup(
                                title: "Workspace",
                                selection: Binding(
                                    get: { recorder.workspace ?? 1 },
                                    set: { recorder.choose(workspace: $0, config: model.snapshot.config) }
                                ),
                                options: recorder.workspaceChoices.map { ($0, "Workspace \($0)") },
                                width: 150
                            )
                        }
                    }
                }
            }
            capture
            HStack(alignment: .top, spacing: GioSpacing.xs) {
                Image(systemName: recorder.tone.symbol)
                    .foregroundStyle(recorder.tone.color)
                Text(recorder.message)
                    .font(GioFont.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: GioSpacing.xs) {
                Spacer(minLength: 0)
                GioButton(title: "Cancel", action: onCancel)
                GioButton(title: recorder.saveTitle ?? "Add", role: .prominent) { onSave(recorder) }
                    .disabled(recorder.saveTitle == nil)
            }
        }
        .padding(GioSpacing.xl)
        .frame(width: 440)
        .background(GioColor.page)
        .onAppear(perform: startRecording)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Hotkeys must not stay off while the user works elsewhere.
            onCancel()
        }
    }

    private var capture: some View {
        HStack {
            Spacer(minLength: 0)
            if let combo = recorder.combo {
                KeyCombo(combo).scaleEffect(1.4)
            } else {
                Text("Recording…")
                    .font(GioFont.body)
                    .foregroundStyle(GioColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.well))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.6), lineWidth: 1.5)
        )
        .accessibilityLabel(recorder.combo.map { "Recorded \($0.describe())" } ?? "Recording, press a key combination")
    }

    private func startRecording() {
        guard !isStatic else {
            return
        }
        model.suspendHotkeys()
        monitor.install { combo in
            switch recorderKey(combo) {
            case .cancel:
                onCancel()
            case .capture(let combo):
                recorder.record(combo, config: model.snapshot.config)
            }
        }
    }

    private func stopRecording() {
        monitor.remove()
        model.resumeHotkeys()
    }
}

/// Owns the local key-down monitor of a recorder sheet. Every key-down in
/// the app goes to the handler and is swallowed while installed.
@MainActor
final class KeyMonitorBox {
    private var token: Any?

    func install(_ handler: @escaping (HotkeyCombo) -> Void) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(recordedCombo(event))
            return nil
        }
    }

    func remove() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }
}

/// The combo of a key-down event; a key outside the vocabulary keeps the
/// character it types so validation can name it.
func recordedCombo(_ event: NSEvent) -> HotkeyCombo {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers = Set<HotkeyModifier>()
    if flags.contains(.control) { modifiers.insert(.ctrl) }
    if flags.contains(.option) { modifiers.insert(.alt) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.cmd) }
    let typed = event.charactersIgnoringModifiers?.uppercased() ?? ""
    let key = hotkeyKeyName(forKeyCode: Int64(event.keyCode)) ?? (typed.isEmpty ? "key \(event.keyCode)" : typed)
    return HotkeyCombo(modifiers: modifiers, key: key)
}
