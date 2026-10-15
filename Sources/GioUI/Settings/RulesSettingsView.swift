import AppKit
import GioCore
import SwiftUI

/// Rule being edited in the sheet; `index` nil for a new one.
struct RuleDraft: Identifiable {
    let id = UUID()
    let index: Int?
    var form: RuleForm
}

/// DD-03 Rules: app icon, name and badges per rule; add and edit in a
/// sheet; delete from the row menu or context menu after confirmation.
/// Every change applies right away (config.toml + reload).
struct RulesSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: RuleDraft?
    @State private var pendingDelete: Int?
    @State private var toast: ApplyToast?

    var body: some View {
        let rules = model.snapshot.config.rules
        SettingsScaffold(
            "Rules", subtitle: "Place, size or float windows of specific apps or titles as they appear.",
            barState: .hidden, toast: $toast, onApply: {}, onRevert: {}
        ) {
            if !rules.isEmpty {
                GioButton(title: "Add Rule", systemImage: "plus", shortcut: KeyboardShortcut("n", modifiers: .command)) {
                    draft = RuleDraft(index: nil, form: RuleForm())
                }
                .help("Add a rule (⌘N)")
            }
        } content: {
            if rules.isEmpty {
                RulesEmptyState { draft = RuleDraft(index: nil, form: RuleForm()) }
            } else {
                SectionCard(
                    "Window Rules",
                    footer: "Rules apply when a window first appears (an untitled window is checked once more when its title arrives). The first matching rule wins: the app name or bundle id exactly, and the title pattern if the rule has one."
                ) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        CardRow(divider: index < rules.count - 1) {
                            RuleRow(
                                presentation: RuleRowPresentation(rule: rule),
                                onEdit: { draft = RuleDraft(index: index, form: RuleForm(rule: rule)) },
                                onDelete: { pendingDelete = index }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $draft) { item in
            RuleEditor(draft: item, displayCount: model.snapshot.facts?.displays.count ?? 1) { form in
                let edit: ConfigEdit = item.index.map { .updateRule(index: $0, form.rule) } ?? .addRule(form.rule)
                toast = ApplyToast(feedback: model.apply([edit]))
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
        .confirmationDialog(
            deleteTitle(rules),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Rule", role: .destructive) {
                if let index = pendingDelete {
                    toast = ApplyToast(feedback: model.apply([.removeRule(index: index)]))
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("New windows of this app will be handled by the default layout. Existing windows stay where they are.")
        }
    }

    private func deleteTitle(_ rules: [WindowRule]) -> String {
        guard let index = pendingDelete, rules.indices.contains(index) else {
            return "Delete this rule?"
        }
        return "Delete the rule for \(RuleRowPresentation(rule: rules[index]).title)?"
    }
}

/// One rule: icon, app name, badges, and an actions menu.
struct RuleRow: View {
    let presentation: RuleRowPresentation
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.gioStaticPage) private var isStatic

    var body: some View {
        if isStatic {
            // Context menus draw a dimming layer through ImageRenderer.
            content
        } else {
            content
                .contextMenu {
                    Button("Edit…", action: onEdit)
                    Button("Delete…", role: .destructive, action: onDelete)
                }
        }
    }

    private var content: some View {
        HStack(spacing: GioSpacing.s) {
            RuleAppIcon(application: presentation.title, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(GioFont.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(GioFont.callout.monospaced())
                        .foregroundStyle(GioColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: GioSpacing.s)
            if presentation.isEmpty {
                StatusBadge(.neutral, "No action", symbol: "minus.circle")
            }
            if let badge = presentation.modeBadge {
                StatusBadge(badge.kind, badge.label, symbol: badge.symbol)
            }
            if let badge = presentation.workspaceBadge {
                StatusBadge(badge.kind, badge.label, symbol: badge.symbol)
            }
            ForEach(presentation.optionBadges, id: \.label) { badge in
                StatusBadge(badge.kind, badge.label, symbol: badge.symbol)
            }
            GioIconMenu("Actions for \(presentation.title)", systemImage: "ellipsis.circle") {
                Button("Edit…", action: onEdit)
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
    }
}

/// Installed app icon for an app name, rasterized once and cached; nil
/// when the app is not found. Rasterizing keeps multi-representation icon
/// files (and their compositing) out of every redraw.
@MainActor
enum AppIconResolver {
    private static var cache: [String: CGImage?] = [:]
    static let pixelSize = 128

    static func icon(named name: String) -> CGImage? {
        if let cached = cache[name] {
            return cached
        }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
        let image = running ?? appBundleCandidates(named: name, home: NSHomeDirectory())
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0) }
        let raster = image.flatMap(rasterizeIcon)
        cache[name] = raster
        return raster
    }

    /// `.some(nil)` when the key was looked up before and not found.
    static func cachedIcon(_ key: String) -> CGImage?? {
        cache[key]
    }

    static func storeIcon(_ image: CGImage?, for key: String) {
        cache[key] = image
    }

    static func rasterizeIcon(_ image: NSImage) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

struct RuleAppIcon: View {
    let application: String
    var size: CGFloat = 28

    var body: some View {
        if application.isEmpty {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(GioColor.secondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: size * 0.86, height: size * 0.86)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let icon = AppIconResolver.icon(named: application) {
            Image(decorative: icon, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            InitialsTile(initials: appInitials(application), size: size * 0.86)
                .frame(width: size, height: size)
        }
    }
}

struct RulesEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: GioSpacing.m) {
            ZStack {
                Circle().fill(GioColor.tint(.orange).opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(GioColor.warningInk)
            }
            .accessibilityHidden(true)
            VStack(spacing: GioSpacing.xxs + 2) {
                Text("No rules yet").font(.system(size: 15, weight: .semibold))
                Text("Float a utility app, or send your chat app to workspace 3 every time it opens.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            GioButton(
                title: "Add Rule", systemImage: "plus", role: .prominent,
                shortcut: KeyboardShortcut("n", modifiers: .command), action: onAdd
            )
        }
        .padding(.vertical, GioSpacing.xxl + 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
        )
    }
}

/// Add / edit sheet: who the rule matches (app, title pattern), where and
/// how the window opens (mode, workspace, display, width, maximized,
/// focus) and its width limits. Validation is `RuleForm.problems`.
struct RuleEditor: View {
    @State private var draft: RuleDraft
    @State private var touched = false
    @State private var minWidthText: String
    @State private var maxWidthText: String
    let displayCount: Int
    let onSave: (RuleForm) -> Void
    let onCancel: () -> Void

    init(
        draft: RuleDraft, displayCount: Int = 1,
        onSave: @escaping (RuleForm) -> Void, onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        _touched = State(initialValue: draft.index != nil)
        _minWidthText = State(initialValue: ruleWidthLimitText(draft.form.minWidth))
        _maxWidthText = State(initialValue: ruleWidthLimitText(draft.form.maxWidth))
        self.displayCount = displayCount
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var runningApps: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap(\.localizedName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.l) {
            HStack(spacing: GioSpacing.s) {
                RuleAppIcon(application: draft.form.app.trimmingCharacters(in: .whitespaces), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.index == nil ? "New Rule" : "Edit Rule").font(.system(size: 15, weight: .semibold))
                    Text("Applies to new windows of this app, or with a matching title.")
                        .font(GioFont.callout)
                        .foregroundStyle(GioColor.secondaryText)
                }
            }
            SectionCard {
                matchRows
                placementRows
                sizeRows
                if touched, !draft.form.problems.isEmpty {
                    VStack(alignment: .leading, spacing: GioSpacing.xxs) {
                        ForEach(draft.form.problems, id: \.self) { InlineProblem($0) }
                    }
                    .padding(.horizontal, GioSpacing.m - 2)
                    .padding(.bottom, GioSpacing.s - 2)
                }
            }
            HStack {
                Spacer()
                GioButton(title: "Cancel", shortcut: .cancelAction, action: onCancel)
                GioButton(title: draft.index == nil ? "Add Rule" : "Save", role: .prominent, shortcut: .defaultAction) {
                    onSave(draft.form)
                }
                .disabled(!draft.form.problems.isEmpty)
            }
        }
        .padding(GioSpacing.xl)
        .frame(width: 560)
        .background(GioColor.page)
    }

    @ViewBuilder
    private var matchRows: some View {
        CardRow {
            SettingRow("App name", caption: "Exactly as shown in the menu bar. Leave empty to match any app by title.") {
                HStack(spacing: GioSpacing.xxs) {
                    GioTextField(title: "App name", text: $draft.form.app, prompt: "Safari", width: 170)
                        .onChange(of: draft.form.app) { _ in touched = true }
                    GioIconMenu("Choose a running app", systemImage: "list.bullet.circle") {
                        ForEach(runningApps, id: \.self) { name in
                            Button(name) { draft.form.app = name }
                        }
                    }
                }
            }
        }
        CardRow {
            SettingRow("Title", caption: "Regular expression, case-insensitive. Empty matches every title.") {
                GioTextField(
                    title: "Title pattern", text: $draft.form.title, prompt: "^Picture in Picture$", width: 200,
                    monospaced: true
                )
                .onChange(of: draft.form.title) { _ in touched = true }
            }
        }
    }

    @ViewBuilder
    private var placementRows: some View {
        CardRow {
            SegmentedRow(
                "Mode", selection: $draft.form.mode,
                options: [(nil, "Any"), (.tiled, "Tiled"), (.floating, "Floating"), (.fullscreen, "Fullscreen")],
                width: 300
            )
        }
        CardRow {
            SettingRow("Workspace", caption: "Where its windows open.") {
                GioPopup(
                    title: "Workspace", selection: $draft.form.workspace,
                    options: [(Int?.none, "Current")] + (1...9).map { (Int?.some($0), "Workspace \($0)") },
                    width: 150
                )
            }
        }
        if ruleShowsDisplayPicker(displayCount: displayCount, current: draft.form.openOnDisplay) {
            CardRow {
                SettingRow("Display", caption: "1 is the main display. A display that is not connected uses the focused one.") {
                    GioPopup(
                        title: "Display", selection: $draft.form.openOnDisplay,
                        options: ruleDisplayOptions(displayCount: displayCount, current: draft.form.openOnDisplay),
                        width: 150
                    )
                }
            }
        }
        CardRow {
            ToggleRow(
                "Take focus", caption: "Off: the window opens without taking focus or switching workspace.",
                isOn: $draft.form.openFocused
            )
        }
    }

    @ViewBuilder
    private var sizeRows: some View {
        CardRow {
            SegmentedRow(
                "Column width",
                selection: Binding(get: { draft.form.widthChoice }, set: { draft.form.adoptWidthChoice($0) }),
                options: [(.layoutDefault, "Default"), (.fraction, "Fraction"), (.points, "Points")], width: 240
            )
        }
        switch draft.form.widthChoice {
        case .layoutDefault:
            EmptyView()
        case .fraction:
            CardRow {
                SliderRow(
                    "Width", value: $draft.form.widthValue, in: 0.1...1, step: 0.01, format: formatPercent
                )
            }
        case .points:
            CardRow {
                SliderRow(
                    "Width", value: $draft.form.widthValue, in: 200...3000, step: 10, format: formatPoints
                )
            }
        }
        CardRow {
            ToggleRow("Open maximized", caption: "Full strip width, like Alt+F.", isOn: $draft.form.openMaximized)
        }
        CardRow(divider: false) {
            SettingRow("Width limits", caption: "Points; empty means no limit. The app's own minimum still wins.") {
                HStack(spacing: GioSpacing.xxs) {
                    GioTextField(title: "Minimum width", text: $minWidthText, prompt: "Min", width: 70, alignment: .trailing)
                        .onChange(of: minWidthText) { text in
                            draft.form.minWidth = ruleWidthLimitValue(text)
                            touched = true
                        }
                    Text("–").foregroundStyle(GioColor.secondaryText)
                    GioTextField(title: "Maximum width", text: $maxWidthText, prompt: "Max", width: 70, alignment: .trailing)
                        .onChange(of: maxWidthText) { text in
                            draft.form.maxWidth = ruleWidthLimitValue(text)
                            touched = true
                        }
                }
            }
        }
    }
}
