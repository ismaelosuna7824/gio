import GioCore
import SwiftUI

/// DD-03 Layout: spacing, column width, window heights (NC-08) and fullscreen gap with a live
/// preview of a display that updates before Apply.
struct LayoutSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: SettingsDraft<LayoutSettingsForm>
    @State private var previewMode: LayoutPreviewMode
    @State private var toast: ApplyToast?
    private let drafts: SettingsDraftStore

    /// `editing` / `previewMode` seed the view for snapshot tests; unsaved
    /// edits come back from `drafts` when the section is shown again.
    init(
        model: DesktopModel, drafts: SettingsDraftStore = SettingsDraftStore(),
        editing: LayoutSettingsForm? = nil, previewMode: LayoutPreviewMode = .columns
    ) {
        self.model = model
        self.drafts = drafts
        let config = model.snapshot.config
        var draft = drafts.restore(for: .layout, saved: LayoutSettingsForm(config: config.layout, dwindle: config.dwindle))
        if let editing {
            draft.current = editing
        }
        _draft = State(initialValue: draft)
        _previewMode = State(initialValue: previewMode)
    }

    private var form: Binding<LayoutSettingsForm> { $draft.current }
    private var defaults: LayoutSettingsForm { layoutDefaults(preserving: draft.current) }

    var body: some View {
        SettingsScaffold(
            "Layout", subtitle: "How columns are sized and spaced on every display.",
            barState: applyBarState(isDirty: draft.isDirty, problems: draft.current.problems),
            toast: $toast, onApply: apply, onRevert: { draft.revert() }
        ) {
            ResetSectionButton(isDisabled: draft.isAtDefaults(defaults)) { draft.reset(to: defaults) }
        } content: {
            previewCard
            spacingCard
            widthCard
            heightCard
            fullscreenCard
            customBarCard
            dwindleCard
        }
        .onReceive(model.$snapshot) { snapshot in
            draft.adopt(saved: LayoutSettingsForm(config: snapshot.config.layout, dwindle: snapshot.config.dwindle))
        }
        .onChange(of: draft) { drafts.store($0, for: .layout) }
    }

    // MARK: Cards

    private var previewCard: some View {
        SectionCard(
            "Preview",
            footer: "Updates as you edit, before Apply. The focused window is ringed and stacked over another one in its column; the neighbors scroll off screen. Ticks mark the preset widths; the keys below are your current bindings."
        ) {
            GioSegmented(
                title: "Preview mode", selection: $previewMode,
                options: LayoutPreviewMode.allCases.map { ($0, $0.title) }, width: 260
            )
        } content: {
            LayoutPreviewView(
                geometry: layoutPreviewGeometry(draft.current, mode: previewMode), mode: previewMode,
                hints: layoutKeyHints(model.snapshot.config)
            )
                .padding(GioSpacing.s)
        }
    }

    private var spacingCard: some View {
        SectionCard("Spacing", footer: "Gaps separate neighboring columns; padding keeps columns away from the screen edges.") {
            CardRow {
                SliderRow("Gaps", value: form.gaps, in: 0...64, step: 1, format: formatPoints)
            }
            CardRow(divider: false) {
                SliderRow("Padding", value: form.padding, in: 0...64, step: 1, format: formatPoints)
            }
            problems(matching: ["Gaps", "Padding"])
        }
    }

    private var widthCard: some View {
        SectionCard(
            "Column Width",
            footer: "New columns open at the default width. Alt+R cycles the focused column through the presets from left to right; click one to change or remove it."
        ) {
            CardRow {
                SegmentedRow(
                    "Default width unit", selection: form.widthKind,
                    options: [(.fraction, "Fraction"), (.points, "Points")], width: 180
                )
            }
            CardRow {
                switch draft.current.widthKind {
                case .fraction:
                    SliderRow(
                        "Default width", value: form.widthValue, in: 0.1...1, step: 0.01, format: formatPercent
                    )
                case .points:
                    SliderRow(
                        "Default width", value: form.widthValue, in: 200...3000, step: 10, format: formatPoints
                    )
                }
            }
            CardRow {
                SettingRow("Preset widths", caption: "Percent of the screen, or a fixed width in points.") {
                    PresetWidthChips(text: form.presetsText)
                }
            }
            CardRow {
                ToggleRow(
                    "Full width when alone",
                    caption: "A workspace with one window shows it at full width, like Alt+F; a second window brings the widths back.",
                    isOn: form.maximizeSingleWindow
                )
            }
            CardRow {
                ToggleRow(
                    "Fill empty space",
                    caption: "Columns that fit the screen stretch to fill it, keeping their relative sizes; more windows bring their widths back. A width you set by hand stays until a window opens or closes.",
                    isOn: form.fillEmptySpace
                )
            }
            CardRow {
                ToggleRow(
                    "Center a lone column",
                    caption: "A workspace with a single column shows it in the middle instead of at the left edge.",
                    isOn: form.alwaysCenterSingleColumn
                )
            }
            CardRow(divider: false) {
                SettingRow("New windows open", caption: "Where a newly opened window's column lands in the strip.") {
                    GioPopup(
                        title: "New windows open", selection: form.newWindowPosition,
                        options: [
                            (.end, "At the end"), (.start, "At the start"),
                            (.rightOfFocused, "Right of the focused column"),
                            (.leftOfFocused, "Left of the focused column"),
                        ],
                        width: 220
                    )
                }
            }
            problems(matching: ["Default width", "Preset widths"])
        }
    }

    /// NC-08: the heights `switch-preset-window-height` cycles a stacked
    /// window through (same chips as the widths).
    private var heightCard: some View {
        SectionCard(
            "Window Height",
            footer: "Windows stacked in a column share its height. Alt+Shift+R cycles the focused one through these presets, Alt+Shift+Minus / Equal step it by 10% and Ctrl+Alt+R gives every window an equal share again."
        ) {
            CardRow(divider: false) {
                SettingRow("Preset heights", caption: "Percent of the screen height, or a fixed height in points.") {
                    PresetWidthChips(text: form.presetHeightsText, axis: .height)
                }
            }
            problems(matching: ["Preset heights"])
        }
    }

    private var fullscreenCard: some View {
        SectionCard(
            "Fullscreen",
            footer: "Space kept around a fullscreen window (Alt+Shift+F); 0 is edge to edge. Fullscreen windows show no focus ring unless \"Hide on maximized windows\" is off in Focus and this gap is at least the ring's width."
        ) {
            CardRow(divider: !draft.current.fullscreenGapFollowsGaps) {
                ToggleRow("Match gaps", caption: "Use the column gap around fullscreen windows.", isOn: form.fullscreenGapFollowsGaps)
            }
            if !draft.current.fullscreenGapFollowsGaps {
                CardRow(divider: false) {
                    SliderRow("Fullscreen gap", value: form.fullscreenGap, in: 0...64, step: 1, format: formatPoints)
                }
            }
            problems(matching: ["Fullscreen"])
        }
    }

    /// SB-01 `[layout] reserved-top`.
    private var customBarCard: some View {
        SectionCard(
            "Custom Bar",
            footer: "Points kept free at the top of every display for a bar such as SketchyBar, below the macOS menu bar when it shows. Fullscreen windows still cover it. See docs/SKETCHYBAR.md."
        ) {
            CardRow(divider: false) {
                SliderRow(
                    "Space for a custom bar (top)", value: form.reservedTop, in: 0...200, step: 1, format: formatPoints
                )
            }
            problems(matching: ["Space for a custom bar"])
        }
    }

    /// DW-03: the layout new workspaces start with and the dwindle tuning.
    private var dwindleCard: some View {
        SectionCard(
            "Workspace Layout",
            footer: "New workspaces open in this layout; Alt+Shift+T switches the current one and Workspaces can set one per named workspace. Dwindle keeps every window on screen: each new window splits the focused one. A workspace with more windows than the maximum stays scrolling, and a dwindle workspace that gets one too many returns to scrolling."
        ) {
            CardRow {
                SegmentedRow(
                    "Default layout", selection: form.defaultLayout,
                    options: [(.scrolling, "Scrolling"), (.dwindle, "Dwindle")], width: 200
                )
            }
            CardRow {
                SliderRow(
                    "Dwindle split ratio", value: form.splitRatio, in: 0.1...1.9, step: 0.05,
                    format: { String(format: "%.0f%% kept", $0 * 50) }
                )
            }
            CardRow {
                SliderRow(
                    "Dwindle width multiplier", value: form.splitWidthMultiplier, in: 0.1...3, step: 0.05,
                    format: { String(format: "%.2fx", $0) }
                )
            }
            CardRow(divider: false) {
                SliderRow(
                    "Dwindle maximum windows",
                    value: Binding(
                        get: { Double(draft.current.maxWindows) },
                        set: { draft.current.maxWindows = Int($0.rounded()) }
                    ),
                    in: 1...12, step: 1, format: { "\(Int($0.rounded()))" }
                )
            }
            problems(matching: ["Dwindle"])
        }
    }

    @ViewBuilder
    private func problems(matching prefixes: [String]) -> some View {
        let found = draft.current.problems.filter { problem in prefixes.contains { problem.hasPrefix($0) } }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: GioSpacing.xxs) {
                ForEach(found, id: \.self) { InlineProblem($0) }
            }
            .padding(.horizontal, GioSpacing.m - 2)
            .padding(.bottom, GioSpacing.s - 2)
        }
    }

    private func apply() {
        guard draft.isDirty, draft.current.problems.isEmpty else {
            return
        }
        let feedback = model.apply(draft.current.edits)
        if case .applied = feedback {
            draft.commit()
        }
        toast = ApplyToast(feedback: feedback)
    }
}

/// The display miniature: a desktop with a menu bar, three columns of
/// windows (title bars, traffic lights, content), the focused one ringed in
/// the accent with a glow, a ruler with the preset widths and (MD-02) the
/// strip's everyday keys as the config binds them.
struct LayoutPreviewView: View {
    let geometry: LayoutPreviewGeometry
    let mode: LayoutPreviewMode
    var hints: [LayoutKeyHint] = []
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rulerHeight: CGFloat = 37
    /// The menu bar above the strip, in display points; a fullscreen window
    /// covers the whole display, menu bar included.
    private var menuBar: CGFloat { mode == .fullscreen ? 0 : 30 }

    var body: some View {
        VStack(spacing: GioSpacing.s) {
            PreviewCanvas(height: 340) {
                GeometryReader { proxy in
                    let display = CGSize(width: geometry.display.width, height: geometry.display.height + menuBar)
                    let available = CGSize(width: proxy.size.width - 48, height: proxy.size.height - 30 - rulerHeight)
                    let scale = min(available.width / display.width, available.height / display.height)
                    let screen = CGSize(width: display.width * scale, height: display.height * scale)
                    let origin = CGPoint(x: (proxy.size.width - screen.width) / 2, y: 16)
                    ZStack(alignment: .topLeading) {
                        screenView(size: screen, scale: scale)
                            .offset(x: origin.x, y: origin.y)
                        ruler(width: screen.width, scale: scale)
                            .offset(x: origin.x, y: origin.y + screen.height + 6)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            if !hints.isEmpty {
                hintGrid
            }
        }
    }

    private var accessibilitySummary: String {
        let focused = geometry.columns[geometry.focusedIndex]
        let percent = Int((focused.width / geometry.display.width * 100).rounded())
        return "Layout preview, \(mode.title.lowercased()): focused column \(percent)% of the screen"
    }

    /// One tile per window: the focused column holds a stack of two in the
    /// Columns preview (the gap between them is the configured gap).
    private struct Tile {
        let rect: CGRect
        let title: String
        let tint: SectionTint
        let focused: Bool
        let column: Int
    }

    private var tiles: [Tile] {
        let titles = ["Browser", "Editor", "Terminal"]
        let tints: [SectionTint] = [.blue, .green, .gray]
        var result: [Tile] = []
        let gap = geometry.columns.count > 1 ? max(geometry.columns[1].minX - geometry.columns[0].maxX, 0) : 0
        for (index, column) in geometry.columns.enumerated() {
            let rect = column.offsetBy(dx: 0, dy: menuBar)
            let focused = index == geometry.focusedIndex
            if focused, mode == .columns, rect.height > gap + 40 {
                let height = (rect.height - gap) / 2
                result.append(Tile(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                                   title: titles[index % 3], tint: tints[index % 3], focused: true, column: index))
                result.append(Tile(rect: CGRect(x: rect.minX, y: rect.minY + height + gap, width: rect.width, height: height),
                                   title: "Notes", tint: .orange, focused: false, column: index))
            } else {
                result.append(Tile(rect: rect, title: titles[index % 3], tint: tints[index % 3], focused: focused, column: index))
            }
        }
        return result
    }

    private func screenView(size: CGSize, scale: CGFloat) -> some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        return ZStack(alignment: .topLeading) {
            PreviewDesktop()
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                PreviewTile(title: tile.title, tint: tile.tint, focused: tile.focused, ring: palette.fill)
                    .frame(width: max(tile.rect.width * scale, 1), height: max(tile.rect.height * scale, 1))
                    .offset(x: tile.rect.minX * scale, y: tile.rect.minY * scale)
                    .opacity(tile.column == geometry.focusedIndex || mode == .columns ? 1 : 0)
            }
            if menuBar > 0 {
                menuBarView
                    .frame(width: size.width, height: menuBar * scale)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.6 : 0.25), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: geometry)
    }

    private var menuBarView: some View {
        HStack(spacing: 9) {
            Text("Gio").fontWeight(.semibold).foregroundStyle(GioColor.primaryText)
            ForEach(["File", "Edit", "View"], id: \.self) { item in
                Text(item).foregroundStyle(GioColor.secondaryText)
            }
            Spacer(minLength: 0)
            Text("9:41").foregroundStyle(GioColor.secondaryText)
        }
        .font(.system(size: 8))
        .padding(.horizontal, 10)
        .background(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08))
    }

    /// The key hints, two to a row like keyboard legends.
    private var hintGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: GioSpacing.s) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: GioSpacing.xs) {
                    KeyCombo(hint.combo)
                    Text(hint.label)
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, GioSpacing.s)
        .padding(.bottom, GioSpacing.xs)
    }

    /// A width scale from the left padding: the default width as a bar,
    /// each preset as a labeled tick.
    private func ruler(width: CGFloat, scale: CGFloat) -> some View {
        let focused = geometry.columns[geometry.focusedIndex]
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        let start = geometry.padding * scale
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(GioColor.secondaryText.opacity(0.3))
                .frame(width: width, height: 1)
                .offset(y: 4)
            Capsule()
                .fill(palette.fill)
                .frame(width: max(focused.width * scale, 2), height: 3)
                .offset(x: start, y: 3)
                .opacity(mode == .columns ? 1 : 0)
            let xs = geometry.presetWidths.map { min(max(start + $0 * scale, 0), width) }
            let lanes = rulerLabelLanes(xs, minimumSpacing: 40)
            ForEach(Array(zip(geometry.presetWidths, geometry.presetLabels).enumerated()), id: \.offset) { index, preset in
                let x = xs[index]
                VStack(spacing: 2) {
                    Rectangle().fill(GioColor.secondaryText).frame(width: 1, height: 9 + CGFloat(lanes[index]) * 11)
                    Text(preset.1)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(GioColor.secondaryText)
                        .fixedSize()
                }
                .frame(width: 44)
                .offset(x: x - 22)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .opacity(mode == .columns ? 1 : 0.4)
    }
}

/// One preview window: a title bar with the traffic lights and the app's
/// name, placeholder content, and for the focused one the accent ring with
/// its glow (what Gio's focus ring looks like on screen).
private struct PreviewTile: View {
    let title: String
    let tint: SectionTint
    let focused: Bool
    let ring: Color

    private static let lights = [
        Color(red: 1.0, green: 0.37, blue: 0.34), Color(red: 1.0, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25),
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(GioColor.raised)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { index in
                            Circle().fill(Self.lights[index]).frame(width: 5, height: 5)
                        }
                        Text(title)
                            .font(.system(size: 7.5))
                            .foregroundStyle(GioColor.secondaryText)
                            .lineLimit(1)
                            .padding(.leading, 3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 14)
                    .background(Color.black.opacity(0.08))
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(GioColor.tint(tint).opacity(0.6)).frame(height: 5)
                            .frame(maxWidth: 70, alignment: .leading)
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(GioColor.secondaryText.opacity(0.18))
                                .frame(height: 4)
                                .padding(.trailing, CGFloat(index % 2) * 18 + 6)
                        }
                    }
                    .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? ring : GioColor.hairline.opacity(0.6), lineWidth: focused ? 2 : 0.5)
            )
            .shadow(color: focused ? ring.opacity(0.55) : .clear, radius: 6)
    }
}
