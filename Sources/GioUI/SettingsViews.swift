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
    @State private var feedback: ApplyFeedback?

    init(model: DesktopModel) {
        self.model = model
        let config = model.snapshot.config
        _form = State(initialValue: LayoutSettingsForm(config: config.layout))
        _focusFollowsMouse = State(initialValue: config.behavior.focusFollowsMouse)
        _mouseFollowsFocus = State(initialValue: config.behavior.mouseFollowsFocus)
    }

    var body: some View {
        Form {
            Section("Columns") {
                numberField("Gaps (points)", $form.gaps)
                numberField("Padding (points)", $form.padding)
                Picker("Default width", selection: $form.widthKind) {
                    Text("Fraction of screen").tag(LayoutSettingsForm.WidthKind.fraction)
                    Text("Points").tag(LayoutSettingsForm.WidthKind.points)
                }
                numberField(form.widthKind == .fraction ? "Width (0-1)" : "Width (points)", $form.widthValue)
                TextField("Preset widths", text: $form.presetsText)
                Text("Comma-separated; values up to 1 are fractions, larger ones points. Alt+R cycles them.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Center the focused column", isOn: $form.centerFocusedColumn)
            }
            Section("Focus") {
                Toggle("Focus follows mouse", isOn: $focusFollowsMouse)
                Toggle("Mouse follows focus", isOn: $mouseFollowsFocus)
            }
            Section {
                HStack {
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!form.problems.isEmpty)
                    Button("Revert") { revert() }
                }
                FeedbackView(problems: form.problems, feedback: feedback)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Layout")
    }

    private func numberField(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number)
    }

    private func apply() {
        feedback = model.apply(
            form.edits + behaviorEdits(focusFollowsMouse: focusFollowsMouse, mouseFollowsFocus: mouseFollowsFocus)
        )
        if case .applied? = feedback {
            revert(keepFeedback: true)
        }
    }

    private func revert(keepFeedback: Bool = false) {
        let config = model.snapshot.config
        form = LayoutSettingsForm(config: config.layout)
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
    @State private var feedback: ApplyFeedback?

    init(model: DesktopModel) {
        self.model = model
        let animations = model.snapshot.config.animations
        _enabled = State(initialValue: animations.enabled)
        _duration = State(initialValue: Double(animations.durationMilliseconds))
    }

    var body: some View {
        Form {
            Section("Motion") {
                Toggle("Animate scrolling and focus changes", isOn: $enabled)
                HStack {
                    Slider(value: $duration, in: 0...1000, step: 10)
                    Text("\(Int(duration)) ms").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                .disabled(!enabled)
                Text("0 ms or off makes every move instant.").font(.caption).foregroundStyle(.secondary)
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
        feedback = model.apply(animationEdits(enabled: enabled, durationMilliseconds: Int(duration)))
    }

    private func revert() {
        let animations = model.snapshot.config.animations
        enabled = animations.enabled
        duration = Double(animations.durationMilliseconds)
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
