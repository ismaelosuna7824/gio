import GioCore
import SwiftUI

/// Inline result of the last Apply: parser messages when rejected, warnings
/// when applied with caveats.
struct FeedbackView: View {
    let problems: [String]
    let feedback: ApplyFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            switch feedback {
            case .applied(let warnings)?:
                Label("Applied and reloaded.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(warnings, id: \.self) { warning in
                    Text(warning).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                }
            case .rejected(let messages)?:
                Label("Not applied; config.toml was left unchanged.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                ForEach(messages, id: \.self) { message in
                    Text(message).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            case nil:
                EmptyView()
            }
        }
        .font(.callout)
    }
}

struct LayoutSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var form: LayoutSettingsForm
    @State private var focusFollowsMouse: Bool
    @State private var mouseFollowsFocus: Bool
    @State private var ring: FocusRingSettingsForm
    @State private var feedback: ApplyFeedback?

    init(model: DesktopModel) {
        self.model = model
        let config = model.snapshot.config
        _form = State(initialValue: LayoutSettingsForm(config: config.layout))
        _ring = State(initialValue: FocusRingSettingsForm(config: config.focusRing))
        _focusFollowsMouse = State(initialValue: config.behavior.focusFollowsMouse)
        _mouseFollowsFocus = State(initialValue: config.behavior.mouseFollowsFocus)
    }

    var body: some View {
        Form {
            Section("Columns") {
                numberField("Gaps (points)", $form.gaps)
                numberField("Padding (points)", $form.padding)
                Toggle("Fullscreen gap follows Gaps", isOn: $form.fullscreenGapFollowsGaps)
                if !form.fullscreenGapFollowsGaps {
                    HStack {
                        Slider(value: $form.fullscreenGap, in: 0...64, step: 1)
                        numberField("Fullscreen gap (0-64 points)", $form.fullscreenGap)
                            .frame(width: 80)
                    }
                }
                Text("Space kept around a fullscreen window (Alt+Shift+F); 0 is edge to edge. The focus ring shows in fullscreen when the gap is at least its width.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default width", selection: $form.widthKind) {
                    Text("Fraction of screen").tag(LayoutSettingsForm.WidthKind.fraction)
                    Text("Points").tag(LayoutSettingsForm.WidthKind.points)
                }
                numberField(form.widthKind == .fraction ? "Width (0-1)" : "Width (points)", $form.widthValue)
                TextField("Preset widths", text: $form.presetsText)
                Text("Comma-separated; values up to 1 are fractions, larger ones points. Alt+R cycles them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Focus") {
                Picker("Center the focused column", selection: $form.centerFocusedColumn) {
                    Text("Never (scroll minimally)").tag(CenterFocusedColumnMode.never)
                    Text("Always").tag(CenterFocusedColumnMode.always)
                    Text("On overflow").tag(CenterFocusedColumnMode.onOverflow)
                }
                Text("Applies to keyboard focus changes. On overflow centers only when the column does not fit next to the previous one.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Focus follows mouse", isOn: $focusFollowsMouse)
                Text("Focuses the window the pointer rests on for about 100 ms. Never scrolls the strip.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mouse follows focus", isOn: $mouseFollowsFocus)
                Text("Moves the cursor to the focused window after a keyboard focus change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Focus ring") {
                Toggle("Draw a ring around the focused window", isOn: $ring.enabled)
                numberField("Width (0-20 points)", $ring.width)
                FocusRingColorRow(form: $ring)
                Text("A click-through outline that follows the focused window, including while it animates. Hidden for minimized, off-screen and fullscreen windows and while Gio itself is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!problems.isEmpty)
                    Button("Revert") { revert() }
                }
                FeedbackView(problems: problems, feedback: feedback)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Layout")
    }

    private var problems: [String] {
        form.problems + ring.problems
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number)
    }

    private func apply() {
        feedback = model.apply(
            form.edits + behaviorEdits(focusFollowsMouse: focusFollowsMouse, mouseFollowsFocus: mouseFollowsFocus)
                + ring.edits
        )
        if case .applied? = feedback {
            revert(keepFeedback: true)
        }
    }

    private func revert(keepFeedback: Bool = false) {
        let config = model.snapshot.config
        form = LayoutSettingsForm(config: config.layout)
        ring = FocusRingSettingsForm(config: config.focusRing)
        focusFollowsMouse = config.behavior.focusFollowsMouse
        mouseFollowsFocus = config.behavior.mouseFollowsFocus
        if !keepFeedback {
            feedback = nil
        }
    }
}

struct AnimationsSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var enabled: Bool
    @State private var duration: Double
    @State private var curve: MotionCurveKind
    @State private var dampingRatio: Double
    @State private var stiffness: Double
    @State private var resize: ResizeMode
    @State private var renderer: RendererKind
    @State private var focusedGrow: FocusedGrowMode
    @State private var nativeZoom: Bool
    @State private var feedback: ApplyFeedback?

    init(model: DesktopModel) {
        self.model = model
        let animations = model.snapshot.config.animations
        _enabled = State(initialValue: animations.enabled)
        _duration = State(initialValue: Double(animations.durationMilliseconds))
        _curve = State(initialValue: animations.curve)
        _dampingRatio = State(initialValue: animations.springDampingRatio)
        _stiffness = State(initialValue: animations.springStiffness)
        _resize = State(initialValue: animations.resize)
        _renderer = State(initialValue: animations.renderer)
        _focusedGrow = State(initialValue: animations.focusedGrow)
        _nativeZoom = State(initialValue: animations.nativeZoom)
    }

    var body: some View {
        Form {
            Section("Motion") {
                Toggle("Animate scrolling and focus changes", isOn: $enabled)
                Picker("Curve", selection: $curve) {
                    Text("Spring").tag(MotionCurveKind.spring)
                    Text("Ease out").tag(MotionCurveKind.easeOut)
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
                if curve == .spring {
                    HStack {
                        Text("Damping")
                        Slider(
                            value: $dampingRatio,
                            in: SpringParameters.dampingRatioRange, step: 0.05
                        )
                        Text(String(format: "%.2f", dampingRatio)).monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .disabled(!enabled)
                    HStack {
                        Text("Stiffness")
                        Slider(value: $stiffness, in: SpringParameters.stiffnessRange, step: 50)
                        Text("\(Int(stiffness))").monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .disabled(!enabled)
                    Text("Damping 1 never overshoots; lower bounces. Higher stiffness is faster. A spring keeps the speed of a move it interrupts, so rapid key presses flow.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Slider(value: $duration, in: 0...1000, step: 10)
                        Text("\(Int(duration)) ms").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                    .disabled(!enabled)
                    Text("0 ms or off makes every move instant.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Resize", selection: $resize) {
                    Text("Never").tag(ResizeMode.never)
                    Text("Adaptive").tag(ResizeMode.adaptive)
                    Text("Always").tag(ResizeMode.always)
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
                Text("Never (default) grows windows once at the end. Adaptive grows them during the motion when their app keeps up and nothing is in the way; Always ignores how well the app keeps up.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Focused window growth", selection: $focusedGrow) {
                    Text("At start").tag(FocusedGrowMode.start)
                    Text("At end").tag(FocusedGrowMode.end)
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
                Text("At start (default) gives the focused window its final size in the first frame of maximize, fullscreen and width changes, so it is not cut while the others slide away. At end waits for the final pass. Adaptive or Always resize keep their own timing when they already grow the window during the motion.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use the app's own zoom to maximize", isOn: $nativeZoom)
                    .disabled(!enabled)
                Text("Maximize (Alt+F) on a single-window column presses the app's zoom, the same as double-clicking its title bar. The app animates it itself, so it does not wait to repaint at the new size. Gio keeps the frame the zoom lands on when it is close to the layout, and falls back to a normal resize otherwise. Stacked columns and apps without a zoom button always use the normal resize.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Renderer", selection: $renderer) {
                    Text("Accessibility").tag(RendererKind.ax)
                    Text("Snapshot (experimental)").tag(RendererKind.snapshot)
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
                Text("Accessibility (default) moves the real windows every frame, so you always see live content. Snapshot (experimental) animates window images in an overlay: smoother on slow apps, but it can flicker and needs the Screen Recording permission (grant it from Overview or Diagnostics).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    Button("Revert") { revert() }
                }
                FeedbackView(problems: [], feedback: feedback)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Animations")
    }

    private func apply() {
        feedback = model.apply(animationEdits(
            enabled: enabled, durationMilliseconds: Int(duration),
            curve: curve, springDampingRatio: dampingRatio, springStiffness: stiffness,
            resize: resize, renderer: renderer, focusedGrow: focusedGrow, nativeZoom: nativeZoom
        ))
    }

    private func revert() {
        let animations = model.snapshot.config.animations
        enabled = animations.enabled
        duration = Double(animations.durationMilliseconds)
        curve = animations.curve
        dampingRatio = animations.springDampingRatio
        stiffness = animations.springStiffness
        resize = animations.resize
        renderer = animations.renderer
        focusedGrow = animations.focusedGrow
        nativeZoom = animations.nativeZoom
        feedback = nil
    }
}

private struct RuleDraft: Identifiable {
    let id = UUID()
    /// Index of the rule being edited; nil for a new one.
    let index: Int?
    var form: RuleForm
}

struct RulesSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: RuleDraft?
    @State private var feedback: ApplyFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Window rules").font(.title2)
                Spacer()
                Button("Add Rule") { draft = RuleDraft(index: nil, form: RuleForm()) }
            }
            Text("Rules apply when a window first appears. The first rule matching the app name exactly wins.")
                .font(.callout).foregroundStyle(.secondary)
            let rules = model.snapshot.config.rules
            if rules.isEmpty {
                Text("No rules yet.").foregroundStyle(.secondary).padding(.top, 8)
            }
            List(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack {
                    Text(rule.app).font(.headline)
                    Spacer()
                    Text(rule.mode?.rawValue ?? "any mode").foregroundStyle(.secondary)
                    Text(rule.workspace.map { "workspace \($0)" } ?? "any workspace").foregroundStyle(.secondary)
                    Button("Edit") { draft = RuleDraft(index: index, form: RuleForm(rule: rule)) }
                    Button("Delete", role: .destructive) { feedback = model.apply([.removeRule(index: index)]) }
                }
            }
            FeedbackView(problems: [], feedback: feedback)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $draft) { item in
            RuleEditor(draft: item) { form in
                let edit: ConfigEdit = item.index.map { .updateRule(index: $0, form.rule) } ?? .addRule(form.rule)
                feedback = model.apply([edit])
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }
}

private struct RuleEditor: View {
    @State var draft: RuleDraft
    let onSave: (RuleForm) -> Void
    let onCancel: () -> Void

    init(draft: RuleDraft, onSave: @escaping (RuleForm) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            TextField("App name", text: $draft.form.app)
            Picker("Mode", selection: $draft.form.mode) {
                Text("Any").tag(WindowMode?.none)
                Text("Tiled").tag(WindowMode?.some(.tiled))
                Text("Floating").tag(WindowMode?.some(.floating))
                Text("Fullscreen").tag(WindowMode?.some(.fullscreen))
            }
            Picker("Workspace", selection: $draft.form.workspace) {
                Text("Any").tag(Int?.none)
                ForEach(1...9, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
            }
            FeedbackView(problems: draft.form.problems, feedback: nil)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.form) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.form.problems.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}


/// NF-03 color picker for the focus ring: native picker (no opacity, the ring
/// is opaque), preset swatches, a hex field and a live preview, all bound to
/// the form's color text.
private struct FocusRingColorRow: View {
    @Binding var form: FocusRingSettingsForm

    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(themeColor: form.color ?? FocusRingSectionConfig.defaultColor) },
            set: { form.setColor($0.themeColor) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(themeColor: form.color ?? FocusRingSectionConfig.defaultColor), lineWidth: 4)
                    .frame(width: 56, height: 32)
                    .opacity(form.color == nil ? 0.3 : 1)
                    .accessibilityLabel("Focus ring color preview")
                ColorPicker("Color", selection: pickerBinding, supportsOpacity: false)
                TextField("Color (hex)", text: $form.colorText)
                    .frame(width: 100)
            }
            HStack(spacing: 6) {
                ForEach(focusRingColorPresets, id: \.self) { hex in
                    if let color = ThemeColor(hex: hex) {
                        Button {
                            form.setColor(color)
                        } label: {
                            Circle()
                                .fill(Color(themeColor: color))
                                .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                                .overlay(
                                    Circle().stroke(Color.accentColor, lineWidth: 2)
                                        .padding(-3)
                                        .opacity(form.color == color ? 1 : 0)
                                )
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                        .accessibilityLabel("Preset \(hex)")
                    }
                }
            }
        }
    }
}

private extension Color {
    /// sRGB, matching the ring renderer (`NSColor(srgbRed:...)`).
    init(themeColor: ThemeColor) {
        self.init(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue, opacity: 1)
    }

    var themeColor: ThemeColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 1)
        return ThemeColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}
