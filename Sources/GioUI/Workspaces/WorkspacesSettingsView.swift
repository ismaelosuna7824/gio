import GioCore
import SwiftUI

/// Which card the app picker adds to.
struct AppPickerTarget: Identifiable {
    let id: String
}

/// NW-03 Workspaces: named workspaces as cards (icon, color, name, display
/// and the apps that open there). Edits stay a draft until Apply, which
/// writes `[[workspace]]` and `[[window-rules]]` blocks and reloads.
struct WorkspacesSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: SettingsDraft<WorkspacesDraft>
    @State private var toast: ApplyToast?
    @State private var pickerTarget: AppPickerTarget?
    @State private var pendingDelete: String?
    @State private var dropTarget: String?
    @Environment(\.gioStaticPage) private var isStatic
    private let drafts: SettingsDraftStore

    init(model: DesktopModel, drafts: SettingsDraftStore = SettingsDraftStore(), editing: WorkspacesDraft? = nil) {
        self.model = model
        self.drafts = drafts
        var draft = drafts.restore(for: .workspaces, saved: WorkspacesDraft(config: model.snapshot.config))
        if let editing {
            draft.current = editing
        }
        _draft = State(initialValue: draft)
    }

    private var displayCount: Int { model.snapshot.facts?.displays.count ?? 1 }

    var body: some View {
        SettingsScaffold(
            "Workspaces", subtitle: "Name your workspaces and choose which apps open on each.",
            barState: applyBarState(isDirty: draft.isDirty, problems: draft.current.problems),
            toast: $toast, onApply: apply, onRevert: { draft.revert() }
        ) {
            if !draft.current.cards.isEmpty {
                GioButton(title: "New Workspace", systemImage: "plus", shortcut: KeyboardShortcut("n", modifiers: .command)) {
                    draft.current.addWorkspace()
                }
                .help("Add a workspace (⌘N)")
            }
        } content: {
            if draft.current.cards.isEmpty {
                WorkspacesEmptyState(
                    onTemplate: { draft.current.addWorkspace(template: $0) },
                    onBlank: { draft.current.addWorkspace() }
                )
            } else {
                VStack(alignment: .leading, spacing: GioSpacing.s) {
                    ForEach(Array(draft.current.cards.enumerated()), id: \.element.id) { index, card in
                        cardView(card, index: index)
                    }
                }
                WorkspacesFooter(summary: workspaceShortcutSummary(draft.current))
            }
        }
        .onReceive(model.$snapshot) { snapshot in
            draft.adopt(saved: WorkspacesDraft(config: snapshot.config))
        }
        .onChange(of: draft) { drafts.store($0, for: .workspaces) }
        .sheet(item: $pickerTarget) { target in
            if let card = draft.current.card(target.id) {
                WorkspaceAppPicker(card: card, draft: draft.current) { apps in
                    draft.current.assign(apps, to: target.id)
                    pickerTarget = nil
                } onCancel: {
                    pickerTarget = nil
                }
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let id = pendingDelete {
                    draft.current.removeWorkspace(id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its windows move to a regular workspace, and its apps stop opening there. Nothing changes until you apply.")
        }
    }

    private var deleteTitle: String {
        guard let id = pendingDelete, let card = draft.current.card(id) else {
            return "Delete this workspace?"
        }
        return "Delete “\(card.trimmedName)”?"
    }

    private func binding(_ id: String) -> Binding<WorkspaceCardDraft> {
        Binding(
            get: { draft.current.card(id) ?? WorkspaceCardDraft(id: id, origin: nil, name: "") },
            set: { updated in
                if let index = draft.current.cards.firstIndex(where: { $0.id == id }) {
                    draft.current.cards[index] = updated
                }
            }
        )
    }

    private func cardView(_ card: WorkspaceCardDraft, index: Int) -> some View {
        WorkspaceCardView(
            card: binding(card.id),
            index: index,
            displayCount: displayCount,
            nameProblem: draft.current.nameProblem(for: card.id),
            canMoveUp: draft.current.canMoveUp(card.id),
            canMoveDown: draft.current.canMoveDown(card.id),
            isDropTarget: dropTarget == card.id,
            actions: WorkspaceCardActions(
                moveUp: { draft.current.moveUp(card.id) },
                moveDown: { draft.current.moveDown(card.id) },
                delete: { pendingDelete = card.id },
                addApps: { pickerTarget = AppPickerTarget(id: card.id) },
                removeApp: { draft.current.removeApp($0, from: card.id) },
                setFollow: { draft.current.setFollow($1, app: $0, in: card.id) }
            )
        )
        .modifier(CardDropTarget(isStatic: isStatic) { dragged in
            guard draft.current.card(dragged) != nil else {
                return false
            }
            draft.current.drop(dragged, onto: card.id)
            return true
        } onTargeted: { targeted in
            if targeted {
                dropTarget = card.id
            } else if dropTarget == card.id {
                dropTarget = nil
            }
        })
    }

    private func apply() {
        guard draft.isDirty, draft.current.problems.isEmpty else {
            return
        }
        let feedback = model.apply(workspaceConfigEdits(config: model.snapshot.config, draft: draft.current))
        if case .applied = feedback {
            draft.commit()
        }
        toast = ApplyToast(feedback: feedback)
    }
}

/// Drop reordering; skipped on static pages (ImageRenderer draws drop
/// targets as a placeholder).
struct CardDropTarget: ViewModifier {
    let isStatic: Bool
    let onDrop: (String) -> Bool
    let onTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if isStatic {
            content
        } else {
            content.dropDestination(for: String.self) { items, _ in
                items.first.map(onDrop) ?? false
            } isTargeted: { onTargeted($0) }
        }
    }
}

struct WorkspaceCardActions {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    let addApps: () -> Void
    let removeApp: (String) -> Void
    let setFollow: (String, WorkspaceFollowPolicy) -> Void
}

/// One workspace: header (drag handle, glyph with icon picker, inline name,
/// order and actions), color, display, and its apps as chips.
struct WorkspaceCardView: View {
    @Binding var card: WorkspaceCardDraft
    let index: Int
    let displayCount: Int
    let nameProblem: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    var isDropTarget = false
    let actions: WorkspaceCardActions
    @State private var showsSymbolPicker = false
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let nameProblem {
                InlineProblem(nameProblem)
                    .padding(.leading, 78)
                    .padding(.trailing, GioSpacing.m)
                    .padding(.bottom, GioSpacing.s - 2)
            }
            Divider().padding(.leading, GioSpacing.m - 2)
            CardRow {
                SettingRow("Color") { colorControls }
            }
            if displayCount > 1 || card.display != nil {
                CardRow {
                    SettingRow("Display", caption: "Where this workspace lives.") {
                        GioPopup(
                            title: "Display for \(card.trimmedName)", selection: $card.display,
                            options: workspaceDisplayOptions(displayCount: displayCount, current: card.display),
                            width: 150
                        )
                    }
                }
            }
            CardRow {
                SettingRow("Layout", caption: "Scrolling strip or dwindle tree; Default follows Layout > Workspace Layout.") {
                    GioPopup(
                        title: "Layout for \(card.trimmedName)", selection: $card.layout,
                        options: workspaceLayoutOptions, width: 150
                    )
                }
            }
            CardRow(divider: false) { appsSection }
        }
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(
                    isDropTarget ? AccentPalette(accent: accent, colorScheme: colorScheme).ink : GioColor.hairline.opacity(0.6),
                    lineWidth: isDropTarget ? 2 : 0.5
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace \(index + 1), \(card.trimmedName)")
        .accessibilityAction(named: "Move Up", actions.moveUp)
        .accessibilityAction(named: "Move Down", actions.moveDown)
    }

    private var subtitle: String {
        let apps = card.apps.count == 1 ? "1 app" : "\(card.apps.count) apps"
        let key = index < 9 ? "⌥\(index + 1)" : "Workspace \(index + 1)"
        return [key, workspaceDisplayLabel(card.display), apps].joined(separator: "  ·  ")
    }

    private var header: some View {
        HStack(spacing: GioSpacing.s - 2) {
            dragHandle
            glyphButton
            VStack(alignment: .leading, spacing: 2) {
                nameField
                Text(subtitle)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: GioSpacing.s)
            orderButtons
            GioIconMenu("Actions for \(card.trimmedName)", systemImage: "ellipsis.circle") {
                Button("Move Up", action: actions.moveUp).disabled(!canMoveUp)
                Button("Move Down", action: actions.moveDown).disabled(!canMoveDown)
                Divider()
                Button("Add Apps…", action: actions.addApps)
                Divider()
                Button("Delete Workspace…", role: .destructive, action: actions.delete)
            }
        }
        .padding(.leading, GioSpacing.xs)
        .padding(.trailing, GioSpacing.m - 2)
        .padding(.vertical, GioSpacing.s - 2)
    }

    @ViewBuilder
    private var dragHandle: some View {
        let handle = Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GioColor.tertiaryText)
            .frame(width: 18, height: 36)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .accessibilityHidden(true)
        if isStatic {
            handle
        } else {
            handle.draggable(card.id) {
                HStack(spacing: GioSpacing.xs) {
                    WorkspaceGlyph(icon: card.icon, color: card.color, size: 24, fallback: "\(index + 1)")
                    Text(card.trimmedName).font(GioFont.headline)
                }
                .padding(GioSpacing.xs)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
            }
        }
    }

    @ViewBuilder
    private var glyphButton: some View {
        let glyph = WorkspaceGlyph(icon: card.icon, color: card.color, size: 36, fallback: "\(index + 1)")
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        if isStatic {
            glyph
        } else {
            Button { showsSymbolPicker = true } label: { glyph }
                .buttonStyle(.plain)
                .help("Choose an icon")
                .accessibilityLabel("Icon for \(card.trimmedName)")
                .popover(isPresented: $showsSymbolPicker, arrowEdge: .bottom) {
                    WorkspaceSymbolPicker(selection: $card.icon, color: card.color)
                }
        }
    }

    @ViewBuilder
    private var nameField: some View {
        if isStatic {
            Text(card.name.isEmpty ? "Name" : card.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(card.name.isEmpty ? GioColor.tertiaryText : GioColor.primaryText)
                .lineLimit(1)
        } else {
            TextField("Name", text: $card.name, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityLabel("Workspace name")
        }
    }

    private var orderButtons: some View {
        HStack(spacing: 2) {
            orderButton("chevron.up", label: "Move Up", enabled: canMoveUp, action: actions.moveUp)
            orderButton("chevron.down", label: "Move Down", enabled: canMoveDown, action: actions.moveDown)
        }
    }

    private func orderButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? GioColor.secondaryText : GioColor.tertiaryText.opacity(0.6))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel("\(label) \(card.trimmedName)")
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(theme: card.color.flatMap(ThemeColor.init(hex:)) ?? ThemeColor(red: 0.56, green: 0.56, blue: 0.58)) },
            set: { card.color = $0.themeColor.hex.lowercased() }
        )
    }

    private var colorControls: some View {
        HStack(spacing: GioSpacing.s - 2) {
            HStack(spacing: 6) {
                ForEach(workspaceColorPresets, id: \.self) { hex in
                    if let color = ThemeColor(hex: hex) {
                        ColorSwatchButton(
                            color: color, label: "Color \(hex)",
                            isSelected: card.color.flatMap(ThemeColor.init(hex:)) == color
                        ) {
                            card.color = hex
                        }
                    }
                }
            }
            GioColorWell(title: "Custom color for \(card.trimmedName)", color: colorBinding)
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps").font(GioFont.body)
                Spacer(minLength: GioSpacing.s)
                Text(card.apps.isEmpty ? "Windows of these apps open here." : "New windows open here.")
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
            }
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(card.apps) { app in
                    WorkspaceAppChip(
                        app: app, workspace: card.trimmedName,
                        onFollow: { actions.setFollow(app.id, $0) },
                        onRemove: { actions.removeApp(app.id) }
                    )
                }
                AddAppChip(action: actions.addApps)
            }
        }
    }
}

/// An assigned app: icon, name, follow hint; its menu sets Follow or
/// removes it.
struct WorkspaceAppChip: View {
    let app: WorkspaceAppAssignment
    let workspace: String
    let onFollow: (WorkspaceFollowPolicy) -> Void
    let onRemove: () -> Void
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.colorScheme) private var colorScheme

    private var followSymbol: String? {
        switch app.follow {
        case .whenActive: return nil
        case .always: return "arrow.forward.circle.fill"
        case .never: return "moon.fill"
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            BundleAppIcon(name: app.app, bundleID: app.bundleID, size: 18)
            Text(app.app.isEmpty ? (app.bundleID ?? "App") : app.app)
                .font(GioFont.callout.weight(.medium))
                .foregroundStyle(GioColor.primaryText)
                .lineLimit(1)
            if let followSymbol {
                Image(systemName: followSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GioColor.secondaryText)
                    .help("Follow: \(workspaceFollowLabel(app.follow))")
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(GioColor.tertiaryText)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(Capsule().fill(GioColor.raised))
        .overlay(Capsule().strokeBorder(GioColor.hairline.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 0.5, y: 0.5)
    }

    var body: some View {
        if isStatic {
            label
        } else {
            Menu {
                Picker("Follow", selection: Binding(get: { app.follow }, set: onFollow)) {
                    ForEach(WorkspaceFollowPolicy.allCases, id: \.self) { policy in
                        Text(workspaceFollowLabel(policy)).tag(policy)
                    }
                }
                .pickerStyle(.inline)
                Text(workspaceFollowCaption(app.follow))
                Divider()
                Button("Remove from \(workspace)", role: .destructive, action: onRemove)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(app.app), follow \(workspaceFollowLabel(app.follow))")
        }
    }
}

/// Dashed "+ Add App" chip.
struct AddAppChip: View {
    let action: () -> Void
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = AccentPalette(accent: accent, colorScheme: colorScheme).ink
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Add App").font(GioFont.callout.weight(.medium))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(ink.opacity(0.08)))
            .overlay(Capsule().strokeBorder(ink.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Choose apps that open on this workspace")
    }
}

/// Order and how-it-works notes under the cards.
struct WorkspacesFooter: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xxs + 2) {
            if !summary.isEmpty {
                Label {
                    Text(summary)
                } icon: {
                    Image(systemName: "keyboard")
                }
            }
            Label {
                Text("Opening an assigned app sends its new windows to its workspace. Follow decides whether you go with them: When Active (default) follows only when you just opened or used the app.")
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
            Label {
                Text("Named workspaces always exist, even when empty. Drag cards or use the arrows to reorder.")
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
        }
        .font(GioFont.caption)
        .foregroundStyle(GioColor.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, GioSpacing.xxs)
    }
}

/// No named workspaces yet: an illustration, templates and a blank start.
struct WorkspacesEmptyState: View {
    let onTemplate: (WorkspaceTemplate) -> Void
    let onBlank: () -> Void

    var body: some View {
        VStack(spacing: GioSpacing.l) {
            illustration
            VStack(spacing: GioSpacing.xxs + 2) {
                Text("Create your first workspace").font(.system(size: 17, weight: .semibold))
                Text("Group apps by what you do. Their windows open on their workspace, and ⌥1…⌥9 take you there.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: GioSpacing.s) {
                Text("START FROM A TEMPLATE")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(GioColor.tertiaryText)
                HStack(spacing: GioSpacing.s - 2) {
                    ForEach(WorkspaceTemplate.allCases) { template in
                        TemplateTile(template: template) { onTemplate(template) }
                    }
                }
            }
            GioButton(title: "Blank Workspace", systemImage: "plus", shortcut: KeyboardShortcut("n", modifiers: .command), action: onBlank)
        }
        .padding(.vertical, GioSpacing.xxl + 4)
        .padding(.horizontal, GioSpacing.xl)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
        )
    }

    /// Three workspace tiles fanned out over a soft disc.
    private var illustration: some View {
        ZStack {
            Circle().fill(GioColor.tint(.cyan).opacity(0.10)).frame(width: 118, height: 118)
            WorkspaceGlyph(icon: WorkspaceTemplate.chat.icon, color: WorkspaceTemplate.chat.color, size: 46)
                .rotationEffect(.degrees(-14))
                .offset(x: -34, y: 8)
            WorkspaceGlyph(icon: WorkspaceTemplate.browsers.icon, color: WorkspaceTemplate.browsers.color, size: 46)
                .rotationEffect(.degrees(14))
                .offset(x: 34, y: 8)
            WorkspaceGlyph(icon: WorkspaceTemplate.code.icon, color: WorkspaceTemplate.code.color, size: 56)
                .offset(y: -6)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .frame(height: 120)
        .accessibilityHidden(true)
    }
}

/// A template quick-add button: glyph, name, "Add".
struct TemplateTile: View {
    let template: WorkspaceTemplate
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: GioSpacing.xs) {
                WorkspaceGlyph(icon: template.icon, color: template.color, size: 34)
                Text(template.name).font(GioFont.callout.weight(.semibold)).foregroundStyle(GioColor.primaryText)
            }
            .frame(width: 104, height: 84)
            .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.raised))
            .overlay(
                RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                    .strokeBorder(GioColor.hairline.opacity(colorScheme == .dark ? 0.9 : 0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Add a \(template.name) workspace")
        .accessibilityLabel("Add \(template.name) workspace")
    }
}
