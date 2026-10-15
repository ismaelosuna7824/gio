import GioCore
import SwiftUI

/// NW-03 icon picker (popover): search plus a grid of curated SF Symbols,
/// drawn in the workspace's color.
struct WorkspaceSymbolPicker: View {
    @Binding var selection: String?
    let color: String?
    @State private var query = ""
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    init(selection: Binding<String?>, color: String?, query: String = "") {
        _selection = selection
        self.color = color
        _query = State(initialValue: query)
    }

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    var body: some View {
        let symbols = filterWorkspaceSymbols(query)
        VStack(alignment: .leading, spacing: GioSpacing.s - 2) {
            GioSearchField(prompt: "Search icons", text: $query, large: false)
            if symbols.isEmpty {
                Text("No icons match “\(query)”.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(symbols, id: \.self) { name in
                        cell(name)
                    }
                }
            }
            HStack {
                Text(selection ?? "No icon")
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.tertiaryText)
                    .lineLimit(1)
                Spacer()
                if selection != nil {
                    GioButton(title: "Use Number", role: .borderless) { selection = nil }
                        .help("Show the workspace's position instead of an icon")
                }
            }
        }
        .padding(GioSpacing.s)
        .frame(width: 8 * 34 + 7 * 6 + GioSpacing.s * 2)
    }

    private func cell(_ name: String) -> some View {
        let selected = selection == name
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        return Button {
            selection = name
        } label: {
            Group {
                if selected {
                    WorkspaceGlyph(icon: name, color: color, size: 30)
                } else {
                    Image(systemName: name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(GioColor.primaryText.opacity(0.85))
                }
            }
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? palette.fill.opacity(0.0) : GioColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? palette.ink : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// NW-03 app picker sheet: running and installed apps with icons, search
/// and multi-select. Apps held by another workspace say so, and the footer
/// confirms that adding them moves them here.
struct WorkspaceAppPicker: View {
    let card: WorkspaceCardDraft
    let draft: WorkspacesDraft
    let onAdd: ([WorkspaceAppAssignment]) -> Void
    let onCancel: () -> Void
    /// Snapshot tests pass a fixed list; the live sheet reads the system.
    private let fixedCandidates: [AppCandidate]?
    @State private var query: String
    @State private var selection: Set<String>
    @StateObject private var catalog = InstalledAppCatalog.shared
    @State private var running: [AppCandidate] = []
    @FocusState private var searchFocused: Bool
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    init(
        card: WorkspaceCardDraft, draft: WorkspacesDraft, candidates: [AppCandidate]? = nil,
        query: String = "", selection: Set<String> = [],
        onAdd: @escaping ([WorkspaceAppAssignment]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.card = card
        self.draft = draft
        self.onAdd = onAdd
        self.onCancel = onCancel
        fixedCandidates = candidates
        _query = State(initialValue: query)
        _selection = State(initialValue: selection)
    }

    private var candidates: [AppCandidate] {
        fixedCandidates ?? mergeAppCandidates(running: running, installed: catalog.installed)
    }

    private var chosen: [AppCandidate] {
        candidates.filter { selection.contains($0.bundleID) }
    }

    private var conflicts: [WorkspaceAppConflict] {
        draft.conflicts(assigning: chosen.map(\.assignment), to: card.id)
    }

    private func owner(of app: AppCandidate) -> WorkspaceCardDraft? {
        draft.cards.first { $0.apps.contains { $0.isSameApp(as: app.assignment) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], GioSpacing.l)
                .padding(.bottom, GioSpacing.s)
            GioSearchField(prompt: "Search apps", text: $query, focus: isStatic ? nil : $searchFocused)
                .padding(.horizontal, GioSpacing.l)
                .padding(.bottom, GioSpacing.s)
            Divider()
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
                .padding(.horizontal, GioSpacing.l)
                .padding(.vertical, GioSpacing.s)
        }
        .frame(width: 520, height: 580)
        .background(GioColor.page)
        .onAppear {
            guard fixedCandidates == nil else {
                return
            }
            running = InstalledAppCatalog.runningApps()
            catalog.loadIfNeeded()
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: GioSpacing.s) {
            WorkspaceGlyph(icon: card.icon, color: card.color, size: 40, fallback: "")
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Apps to \(card.trimmedName)").font(.system(size: 15, weight: .semibold))
                Text("New windows of these apps will open on \(card.trimmedName).")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        let filtered = filterAppCandidates(candidates, query: query)
        let live = filtered.filter(\.isRunning)
        let installed = filtered.filter { !$0.isRunning }
        let rows = VStack(alignment: .leading, spacing: 0) {
            if filtered.isEmpty {
                if fixedCandidates == nil, catalog.isLoading {
                    EmptyStateView(symbol: "hourglass", title: "Looking for apps…", message: "Reading your Applications folders.")
                } else {
                    EmptyStateView(symbol: "magnifyingglass", title: "No apps found", message: "Nothing matches “\(query)”.")
                }
            }
            if !live.isEmpty {
                sectionHeader("Running")
                ForEach(live) { row($0) }
            }
            if !installed.isEmpty {
                sectionHeader("Installed")
                ForEach(installed) { row($0) }
            }
        }
        .padding(.horizontal, GioSpacing.s)
        .padding(.bottom, GioSpacing.s)
        if isStatic {
            rows.frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { rows }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(GioColor.tertiaryText)
            .padding(.horizontal, GioSpacing.xs)
            .padding(.top, GioSpacing.s)
            .padding(.bottom, GioSpacing.xxs)
    }

    private func row(_ app: AppCandidate) -> some View {
        let owner = owner(of: app)
        let alreadyHere = owner?.id == card.id
        let selected = alreadyHere || selection.contains(app.bundleID)
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        return Button {
            guard !alreadyHere else {
                return
            }
            if selection.contains(app.bundleID) {
                selection.remove(app.bundleID)
            } else {
                selection.insert(app.bundleID)
            }
        } label: {
            HStack(spacing: GioSpacing.s - 2) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? palette.ink : GioColor.tertiaryText)
                    .opacity(alreadyHere ? 0.5 : 1)
                BundleAppIcon(name: app.name, bundleID: app.bundleID, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(GioFont.body.weight(.medium)).lineLimit(1)
                    Text(app.bundleID)
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: GioSpacing.s)
                if alreadyHere {
                    InlineTag(text: "Added")
                } else if let owner {
                    InlineTag(text: "In \(owner.trimmedName)", tint: GioColor.warning, ink: GioColor.warningInk)
                }
            }
            .padding(.horizontal, GioSpacing.xs)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection.contains(app.bundleID) ? palette.fill.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyHere)
        .accessibilityLabel(app.name)
        .accessibilityValue(alreadyHere ? "Already added" : (owner.map { "In \($0.trimmedName)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var confirmTitle: String {
        let count = chosen.count
        if count == 0 {
            return "Add Apps"
        }
        let noun = count == 1 ? "App" : "\(count) Apps"
        return conflicts.isEmpty ? "Add \(noun)" : "Move & Add \(noun)"
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: GioSpacing.s) {
            if !conflicts.isEmpty {
                Label {
                    Text(conflictMessage)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.right.arrow.left.circle.fill")
                        .foregroundStyle(GioColor.warningInk)
                }
                .font(GioFont.caption)
                .foregroundStyle(GioColor.secondaryText)
            } else {
                Text(chosen.isEmpty ? "Select one or more apps." : "\(chosen.count) selected")
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
            }
            Spacer(minLength: GioSpacing.s)
            GioButton(title: "Cancel", shortcut: .cancelAction, action: onCancel)
            GioButton(title: confirmTitle, role: .prominent, shortcut: .defaultAction) {
                onAdd(chosen.map(\.assignment))
            }
            .disabled(chosen.isEmpty)
        }
    }

    private var conflictMessage: String {
        let parts = conflicts.map { "\($0.app) from \($0.from)" }
        return "Moves " + parts.joined(separator: ", ") + " to \(card.trimmedName)."
    }
}
