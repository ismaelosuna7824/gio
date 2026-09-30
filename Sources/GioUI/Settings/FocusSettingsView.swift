import GioCore
import SwiftUI

/// DD-03 Focus: which indicator marks the focused window (with a preview of
/// three sample windows), ring settings, centering and pointer behavior.
struct FocusSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: SettingsDraft<FocusSectionDraft>
    @State private var toast: ApplyToast?
    private let drafts: SettingsDraftStore

    init(model: DesktopModel, drafts: SettingsDraftStore = SettingsDraftStore(), editing: FocusSectionDraft? = nil) {
        self.model = model
        self.drafts = drafts
        var draft = drafts.restore(for: .focus, saved: FocusSectionDraft(config: model.snapshot.config))
        if let editing {
            draft.current = editing
        }
        _draft = State(initialValue: draft)
    }

    private var current: Binding<FocusSectionDraft> { $draft.current }
    private var defaults: FocusSectionDraft { FocusSectionDraft(config: GioConfig()) }

    var body: some View {
        SettingsScaffold(
            "Focus", subtitle: "How the focused window stands out, and how focus follows you.",
            barState: applyBarState(isDirty: draft.isDirty, problems: draft.current.problems),
            toast: $toast, onApply: apply, onRevert: { draft.revert() }
        ) {
            ResetSectionButton(isDisabled: draft.isAtDefaults(defaults)) { draft.reset(to: defaults) }
        } content: {
            indicatorCard
            if draft.current.indicator.indicator == .ring {
                ringCard
            }
            scrollingCard
            pointerCard
        }
        .onReceive(model.$snapshot) { snapshot in
            draft.adopt(saved: FocusSectionDraft(config: snapshot.config))
        }
        .onChange(of: draft) { drafts.store($0, for: .focus) }
    }

    private var indicatorFooter: String {
        switch draft.current.indicator.indicator {
        case .dim:
            return "Darkens the other visible tiled windows while nothing moves; the focused window stays lit. Floating windows, popovers and other apps' windows in front are never dimmed."
        case .ring:
            return "A click-through outline that follows the focused window, including while it animates. Hidden for minimized and off-screen windows, and while Gio itself is active."
        case .none:
            return "No focus indicator is drawn."
        }
    }

    private var indicatorCard: some View {
        SectionCard("Focus Indicator", footer: indicatorFooter) {
            FocusPreviewView(style: focusPreviewStyle(draft.current))
                .padding(GioSpacing.s)
            Divider().padding(.leading, GioSpacing.m - 2)
            CardRow(divider: draft.current.indicator.indicator == .dim) {
                SegmentedRow(
                    "Indicator", selection: current.indicator.indicator,
                    options: [(.dim, "Dim"), (.ring, "Ring"), (.none, "None")], width: 220
                )
            }
            if draft.current.indicator.indicator == .dim {
                CardRow(divider: false) {
                    SliderRow(
                        "Dim strength", caption: "How dark the unfocused windows get.",
                        value: current.indicator.dimStrength, in: FocusSectionConfig.dimStrengthRange,
                        step: 0.01, format: formatPercent
                    )
                }
                ForEach(draft.current.indicator.problems, id: \.self) { problem in
                    InlineProblem(problem).padding(.horizontal, GioSpacing.m - 2).padding(.bottom, GioSpacing.s - 2)
                }
            }
        }
    }

    private var ringCard: some View {
        SectionCard("Ring") {
            CardRow {
                ToggleRow("Show ring", isOn: current.ring.enabled)
            }
            CardRow {
                SliderRow(
                    "Width", value: current.ring.width,
                    in: Double(FocusRingSectionConfig.widthRange.lowerBound)...Double(FocusRingSectionConfig.widthRange.upperBound),
                    step: 1, format: formatPoints
                )
            }
            CardRow {
                FocusRingColorRow(form: current.ring)
            }
            CardRow(divider: false) {
                ToggleRow(
                    "Hide on maximized windows",
                    caption: "Also hides it on fullscreen windows. With this off, fullscreen shows the ring only when the fullscreen gap fits it.",
                    isOn: current.ring.hideWhenMaximized
                )
            }
            ForEach(draft.current.ring.problems, id: \.self) { problem in
                InlineProblem(problem).padding(.horizontal, GioSpacing.m - 2).padding(.bottom, GioSpacing.s - 2)
            }
        }
    }

    private var scrollingCard: some View {
        SectionCard(
            "Scrolling",
            footer: "Applies to keyboard focus changes. On overflow centers only when the column does not fit next to the previous one."
        ) {
            CardRow(divider: false) {
                SettingRow("Center the focused column") {
                    GioPopup(
                        title: "Center the focused column", selection: current.centerFocusedColumn,
                        options: [(.never, "Never"), (.always, "Always"), (.onOverflow, "On overflow")], width: 150
                    )
                }
            }
        }
    }

    private var pointerCard: some View {
        SectionCard("Pointer") {
            CardRow {
                ToggleRow(
                    "Mouse follows focus",
                    caption: "Moves the cursor to the focused window after a keyboard focus change.",
                    isOn: current.mouseFollowsFocus
                )
            }
            CardRow(divider: false) {
                ToggleRow(
                    "Focus follows mouse",
                    caption: "Focuses the window the pointer rests on for about 100 ms. Never scrolls the strip.",
                    isOn: current.focusFollowsMouse
                )
            }
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

/// Three sample windows on a desktop; the middle one has focus.
struct FocusPreviewView: View {
    let style: FocusPreviewStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PreviewCanvas(height: 160) {
            ZStack {
                PreviewDesktop()
                // A strip: equal columns, the neighbors running off the edges.
                HStack(spacing: 12) {
                    window(tint: .green, focused: false).frame(width: 230)
                    window(tint: .blue, focused: true).frame(width: 230)
                    window(tint: .orange, focused: false).frame(width: 230)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if style.ringWidth > 0 {
            return "Preview: the focused window has a \(Int(style.ringWidth)) point ring"
        }
        if style.unfocusedDim > 0 {
            return "Preview: unfocused windows dimmed \(Int((style.unfocusedDim * 100).rounded()))%"
        }
        return "Preview: no focus indicator"
    }

    private func window(tint: SectionTint, focused: Bool) -> some View {
        MiniWindow(tint: tint, cornerRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(focused ? 0 : style.unfocusedDim))
            )
            .overlay(
                // The real ring sits outside the frame; scaled to the preview.
                RoundedRectangle(cornerRadius: 6 + style.ringWidth / 4, style: .continuous)
                    .stroke(style.ringColor.map { Color(theme: $0) } ?? .clear, lineWidth: max(style.ringWidth / 2, 0))
                    .padding(-style.ringWidth / 4)
                    .opacity(focused && style.ringWidth > 0 ? 1 : 0)
            )
    }
}

/// NF-03 color picker for the focus ring: native picker (no opacity, the ring
/// is opaque), preset swatches and a hex field, all bound to the form's color
/// text.
struct FocusRingColorRow: View {
    @Binding var form: FocusRingSettingsForm

    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(theme: form.color ?? FocusRingSectionConfig.defaultColor) },
            set: { form.setColor($0.themeColor) }
        )
    }

    var body: some View {
        SettingRow("Color") {
            HStack(spacing: GioSpacing.s - 2) {
                HStack(spacing: 6) {
                    ForEach(focusRingColorPresets, id: \.self) { hex in
                        if let color = ThemeColor(hex: hex) {
                            swatch(color, hex: hex)
                        }
                    }
                }
                GioColorWell(title: "Custom ring color", color: pickerBinding)
                GioTextField(title: "Ring color hex", text: $form.colorText, width: 84, monospaced: true)
            }
        }
    }

    private func swatch(_ color: ThemeColor, hex: String) -> some View {
        let selected = form.color == color
        return Button {
            form.setColor(color)
        } label: {
            Circle()
                .fill(Color(theme: color))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .overlay(
                    Circle().strokeBorder(GioColor.primaryText.opacity(0.75), lineWidth: 1.5)
                        .padding(-3.5)
                        .opacity(selected ? 1 : 0)
                )
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(hex)
        .accessibilityLabel("Preset \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
