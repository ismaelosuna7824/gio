import GioCore
import GioMacOS
import SwiftUI

/// Overview section: refreshes from the host snapshot while visible and
/// hands plain values to the dashboard.
struct OverviewView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.onboardingPresenter) private var onboarding

    var body: some View {
        OverviewDashboard(
            facts: model.snapshot.facts,
            config: model.snapshot.config,
            showGuide: onboarding.map { presenter in { presenter.present() } },
            requestAccessibility: {
                _ = requestAXPermission()
                model.refresh()
            },
            requestScreenRecording: {
                _ = requestScreenRecordingPermission()
                model.markScreenRecordingRequested()
                model.refresh()
            }
        )
        .onAppear { model.refresh() }
        .pollWhileVisible(model, every: 3) { model.refresh() }
    }
}

/// DD-02 dashboard (presentational): hero metrics, the live workspace
/// strip, permissions and status, workspace stacks and the window list.
struct OverviewDashboard: View {
    let facts: SessionFacts?
    let config: GioConfig
    var showGuide: (() -> Void)?
    var requestAccessibility: () -> Void = {}
    var requestScreenRecording: () -> Void = {}

    var body: some View {
        GioPage("Overview", subtitle: subtitle) {
            if let showGuide {
                GioButton(title: "Setup Guide", systemImage: "sparkles", role: .borderless, action: showGuide)
                    .help("Permissions and the keys to know")
            }
        } content: {
            if let facts {
                let overview = makeOverview(facts)
                if !facts.accessibilityGranted {
                    accessibilityBanner
                }
                heroRow(facts, overview)
                stripCard(facts)
                HStack(alignment: .top, spacing: GioSpacing.m) {
                    statusCard(facts, overview)
                    displaysCard(facts)
                        .frame(width: 236)
                }
                windowsCard(facts, overview)
            } else {
                waitingState
            }
        }
    }

    private var subtitle: String {
        guard let facts else {
            return "Connecting to the tiling session…"
        }
        let displays = facts.displays.count
        return "Tiling \(displays == 1 ? "one display" : "\(max(displays, 1)) displays") · workspace \(facts.currentWorkspace) in focus"
    }

    // MARK: - Empty states

    private var waitingState: some View {
        SectionCard {
            VStack(spacing: GioSpacing.s) {
                Image(systemName: "hourglass")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(GioColor.tertiaryText)
                Text("Waiting for the session").font(GioFont.headline)
                Text("Gio is starting up. Workspaces and windows appear here as soon as the first layout runs.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, GioSpacing.xxl)
        }
    }

    private var accessibilityBanner: some View {
        HStack(alignment: .center, spacing: GioSpacing.m) {
            SectionIcon(symbol: "hand.raised.fill", tint: .blue, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gio needs Accessibility access").font(GioFont.headline)
                Text("Without it Gio cannot move windows or hear your shortcuts. Grant it in System Settings, then come back here.")
                    .font(GioFont.callout)
                    .foregroundStyle(GioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: GioSpacing.s)
            Button("Grant Access…", action: requestAccessibility)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(GioSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                .fill(GioColor.info.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                .strokeBorder(GioColor.info.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Hero

    private func heroRow(_ facts: SessionFacts, _ overview: Overview) -> some View {
        let counts = windowCounts(overview.windows)
        let focused = focusedWindow(facts)
        let motion = motionSummary(config.animations, screenRecording: facts.screenRecordingGranted)
        return HStack(alignment: .top, spacing: GioSpacing.s) {
            MetricTile(
                "Workspaces", value: workspaceTotals(facts),
                detail: facts.displays.count > 1 ? "\(facts.displays.count) displays" : "Focused display",
                symbol: "square.stack.3d.up.fill", tint: .indigo
            )
            MetricTile(
                "Windows", value: "\(counts.total)", detail: counts.detail,
                symbol: "macwindow.on.rectangle", tint: .blue
            )
            MetricTile(
                "Focused", value: focused?.application ?? "None",
                detail: focused.map { $0.title.isEmpty ? "Untitled window" : $0.title } ?? "No managed window",
                symbol: "scope", tint: .orange
            )
            MetricTile("Motion", value: motion.value, detail: motion.detail, symbol: "sparkles", tint: .pink)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func focusedWindow(_ facts: SessionFacts) -> WindowFact? {
        guard let id = facts.strip?.focusedWindowID else {
            return nil
        }
        return facts.windows.first { $0.id == id }
    }

    // MARK: - Strip

    private func stripCard(_ facts: SessionFacts) -> some View {
        let strip = facts.strip
        let columns = strip?.columns.count ?? 0
        return SectionCard(
            stripTitle(facts),
            footer: "A live map of the focused display. The frame is what is on screen; faded columns are parked off screen until you scroll to them.",
            accessory: {
                Text(columns == 1 ? "1 column" : "\(columns) columns")
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
            },
            content: {
                PreviewCanvas(height: 168) {
                    if let strip, !strip.columns.isEmpty {
                        WorkspaceStripView(miniature: workspaceMiniature(strip))
                    } else {
                        VStack(spacing: GioSpacing.xxs) {
                            Image(systemName: "rectangle.dashed")
                                .font(.system(size: 22))
                                .foregroundStyle(GioColor.tertiaryText)
                            Text("No tiled windows on this workspace")
                                .font(GioFont.callout)
                                .foregroundStyle(GioColor.secondaryText)
                        }
                    }
                }
                .padding(GioSpacing.s)
            }
        )
    }

    // MARK: - Status

    private func statusCard(_ facts: SessionFacts, _ overview: Overview) -> some View {
        SectionCard("Status") {
            CardRow {
                statusRow(
                    symbol: "hand.raised.fill", tint: .blue, title: "Accessibility",
                    why: "Moves windows and listens for shortcuts.",
                    granted: facts.accessibilityGranted, action: ("Grant Access…", requestAccessibility)
                )
            }
            CardRow {
                statusRow(
                    symbol: "record.circle", tint: .pink, title: "Screen Recording",
                    why: facts.screenRecordingGranted
                        ? "Powers smooth snapshot animations."
                        : "Optional. Enables smooth snapshot animations; relaunch Gio after granting.",
                    granted: facts.screenRecordingGranted, action: ("Request Access…", requestScreenRecording),
                    missingKind: .warning, missingLabel: "Off"
                )
            }
            CardRow(divider: false) {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    HStack(spacing: GioSpacing.s) {
                        SectionIcon(symbol: "doc.text.fill", tint: .gray, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Configuration").font(GioFont.body)
                            Text(overview.configSummary)
                                .font(GioFont.caption)
                                .foregroundStyle(GioColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: GioSpacing.xs)
                        if overview.configIssues.isEmpty {
                            StatusBadge(.ok, facts.configExists ? "Valid" : "Defaults")
                        } else {
                            StatusBadge(.warning, overview.configIssues.count == 1 ? "1 issue" : "\(overview.configIssues.count) issues")
                        }
                    }
                    ForEach(Array(overview.configIssues.enumerated()), id: \.offset) { _, issue in
                        Text(issue)
                            .font(GioFont.mono)
                            .foregroundStyle(GioColor.ink(.systemOrange))
                            .textSelection(.enabled)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }

    private func statusRow(
        symbol: String, tint: SectionTint, title: String, why: String, granted: Bool,
        action: (String, () -> Void), missingKind: StatusKind = .error, missingLabel: String = "Missing"
    ) -> some View {
        HStack(spacing: GioSpacing.s) {
            SectionIcon(symbol: symbol, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(GioFont.body)
                Text(why)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: GioSpacing.xs)
            if granted {
                StatusBadge(.ok, "Granted")
            } else {
                StatusBadge(missingKind, missingLabel)
                Button(action.0, action: action.1)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Displays

    private func displaysCard(_ facts: SessionFacts) -> some View {
        let displays = facts.displays.sorted { $0.id < $1.id }
        return SectionCard("Workspaces") {
            ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                CardRow(divider: index < displays.count - 1) {
                    VStack(alignment: .leading, spacing: GioSpacing.xs) {
                        HStack(spacing: GioSpacing.xxs + 2) {
                            Image(systemName: "display")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(GioColor.secondaryText)
                            Text(displays.count > 1 ? "Display \(index + 1)" : "Display")
                                .font(GioFont.captionEmphasis)
                                .foregroundStyle(GioColor.secondaryText)
                            if display.id == facts.strip?.displayID, displays.count > 1 {
                                StatusBadge(.info, "Focused")
                            }
                        }
                        VStack(spacing: GioSpacing.xxs) {
                            ForEach(display.stack.isEmpty ? [WorkspaceEntry(index: display.workspace, windows: 0, columns: 0, isActive: true)] : display.stack, id: \.index) { entry in
                                WorkspacePill(entry: entry)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Windows

    private func windowsCard(_ facts: SessionFacts, _ overview: Overview) -> some View {
        let groups = groupWindowRows(overview.windows, activeWorkspace: facts.currentWorkspace)
        return SectionCard(
            "Windows",
            accessory: {
                Text(overview.windowSummary)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
            },
            content: {
                if groups.isEmpty {
                    CardRow(divider: false) {
                        Text("No windows are managed yet. Open an app and Gio tiles it here.")
                            .font(GioFont.callout)
                            .foregroundStyle(GioColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, GioSpacing.s)
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                    HStack(spacing: GioSpacing.xs) {
                        Text(windowGroupTitle(workspace: group.workspace, facts: facts).uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(GioColor.secondaryText)
                        if group.isActive {
                            Circle().fill(GioColor.ok).frame(width: 6, height: 6)
                        }
                        Spacer()
                        Text("\(group.rows.count)")
                            .font(GioFont.caption.monospacedDigit())
                            .foregroundStyle(GioColor.tertiaryText)
                    }
                    .padding(.horizontal, GioSpacing.m - 2)
                    .padding(.top, groupIndex == 0 ? GioSpacing.s : GioSpacing.m)
                    .padding(.bottom, GioSpacing.xxs)
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { rowIndex, row in
                        CardRow(divider: rowIndex < group.rows.count - 1) {
                            windowRow(row)
                        }
                    }
                }
            }
        )
    }

    private func windowRow(_ row: WindowRow) -> some View {
        let badge = windowStateBadge(row.state)
        return HStack(spacing: GioSpacing.s) {
            AppIconView(windowID: row.id, application: row.application, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.application).font(GioFont.body.weight(.medium)).lineLimit(1)
                Text(row.title)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: GioSpacing.s)
            StatusBadge(badge.kind, badge.label, symbol: badge.symbol)
        }
        .opacity(row.state == .minimized || row.state == .hidden ? 0.72 : 1)
    }
}

/// One workspace of a display's stack: index (or a named workspace's
/// glyph and "1 · Code"), window count, active state.
struct WorkspacePill: View {
    let entry: WorkspaceEntry
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    private var count: String {
        entry.windows == 0 ? "Empty" : (entry.windows == 1 ? "1 window" : "\(entry.windows) windows")
    }

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        HStack(spacing: GioSpacing.xs) {
            if entry.name != nil {
                WorkspaceGlyph(icon: entry.icon, color: entry.color, size: 20, fallback: "\(entry.index)")
                    .overlay(
                        RoundedRectangle(cornerRadius: 20 * 0.26, style: .continuous)
                            .strokeBorder(palette.onFill.opacity(entry.isActive ? 0.55 : 0), lineWidth: 1)
                    )
                Text(workspaceTitle(entry))
                    .font(GioFont.callout.weight(entry.isActive ? .semibold : .medium))
                    .foregroundStyle(entry.isActive ? palette.onFill : GioColor.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: GioSpacing.xxs)
                HStack(spacing: 3) {
                    if entry.windows > 0 {
                        Image(systemName: "macwindow").font(.system(size: 9, weight: .semibold))
                    }
                    Text(compactWindowCount(entry.windows)).font(GioFont.caption.monospacedDigit())
                }
                .foregroundStyle(entry.isActive ? palette.onFill : GioColor.secondaryText)
                .fixedSize()
                .help(count)
                .accessibilityLabel(count)
            } else {
                Text("\(entry.index)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(entry.isActive ? palette.fill : GioColor.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(entry.isActive ? palette.onFill : GioColor.card))
                Text(count)
                    .font(entry.isActive ? GioFont.callout.weight(.medium) : GioFont.callout)
                    .foregroundStyle(entry.isActive ? palette.onFill : (entry.windows == 0 ? GioColor.tertiaryText : GioColor.primaryText))
                Spacer(minLength: 0)
            }
            if entry.isActive {
                Text("Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.onFill)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(entry.isActive ? AnyShapeStyle(palette.fill) : AnyShapeStyle(GioColor.raised))
        )
        .overlay(Capsule().strokeBorder(entry.isActive ? Color.clear : GioColor.hairline.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
