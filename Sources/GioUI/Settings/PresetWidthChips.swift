import GioCore
import SwiftUI

/// Preset widths (or, NC-08, heights) as chips: click one to edit or remove
/// it, "+" adds one. Reads and writes the same comma-separated config text.
struct PresetWidthChips: View {
    @Binding var text: String
    var axis: PresetAxis = .width
    @State private var editing: PresetWidthEditTarget?

    var body: some View {
        let values = presetWidthValues(text)
        HStack(spacing: GioSpacing.xs - 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Button {
                    editing = .existing(index)
                } label: {
                    PresetWidthChip(label: presetWidthLabel(value))
                }
                .buttonStyle(.plain)
                .help("Edit this preset")
                .accessibilityLabel("Preset \(presetWidthLabel(value))")
                .accessibilityHint("Edit or remove")
                .popover(isPresented: isEditing(.existing(index)), arrowEdge: .bottom) {
                    PresetWidthEditor(
                        value: PresetWidthEditorValue(value: value), axis: axis, isNew: false, canRemove: values.count > 1,
                        onDone: { replace(at: index, with: $0) },
                        onRemove: { remove(at: index) },
                        onCancel: { editing = nil }
                    )
                }
            }
            Button {
                editing = .new
            } label: {
                PresetWidthAddChip()
            }
            .buttonStyle(.plain)
            .help("Add a preset \(axis.noun)")
            .accessibilityLabel("Add preset \(axis.noun)")
            .popover(isPresented: isEditing(.new), arrowEdge: .bottom) {
                PresetWidthEditor(
                    value: PresetWidthEditorValue(value: nil), axis: axis, isNew: true, canRemove: false,
                    onDone: append, onRemove: {}, onCancel: { editing = nil }
                )
            }
        }
        .fixedSize()
    }

    private func isEditing(_ target: PresetWidthEditTarget) -> Binding<Bool> {
        Binding(get: { editing == target }, set: { if !$0, editing == target { editing = nil } })
    }

    private func replace(at index: Int, with value: Double) {
        var values = presetWidthValues(text)
        if values.indices.contains(index) {
            values[index] = value
            text = presetWidthsText(values)
        }
        editing = nil
    }

    private func remove(at index: Int) {
        var values = presetWidthValues(text)
        if values.indices.contains(index), values.count > 1 {
            values.remove(at: index)
            text = presetWidthsText(values)
        }
        editing = nil
    }

    private func append(_ value: Double) {
        text = presetWidthsText(presetWidthValues(text) + [value])
        editing = nil
    }
}

private enum PresetWidthEditTarget: Equatable {
    case existing(Int)
    case new
}

struct PresetWidthChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(GioFont.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(GioColor.primaryText)
            .padding(.horizontal, GioSpacing.xs + 1)
            .frame(height: 22)
            .background(Capsule().fill(GioColor.raised))
            .overlay(Capsule().strokeBorder(GioColor.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
            .contentShape(Capsule())
    }
}

struct PresetWidthAddChip: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(GioColor.secondaryText)
            .frame(width: 22, height: 22)
            .overlay(
                Circle().strokeBorder(GioColor.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
            )
            .contentShape(Circle())
    }
}

/// Popover body: amount and unit, live validation, Done / Remove.
struct PresetWidthEditor: View {
    @State private var value: PresetWidthEditorValue
    let axis: PresetAxis
    let isNew: Bool
    let canRemove: Bool
    let onDone: (Double) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    init(
        value: PresetWidthEditorValue, axis: PresetAxis = .width, isNew: Bool, canRemove: Bool,
        onDone: @escaping (Double) -> Void, onRemove: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        _value = State(initialValue: value)
        self.axis = axis
        self.isNew = isNew
        self.canRemove = canRemove
        self.onDone = onDone
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.s) {
            Text("\(isNew ? "Add" : "Edit") Preset \(axis.noun.capitalized)").font(GioFont.headline)
            HStack(spacing: GioSpacing.xs) {
                GioTextField(title: axis.noun.capitalized, text: $value.amount, prompt: "50", width: 72, alignment: .trailing)
                    .onSubmit(commit)
                GioSegmented(
                    title: "Unit", selection: $value.unit,
                    options: PresetWidthUnit.allCases.map { ($0, $0.title) }, width: 150
                )
            }
            Group {
                if let problem = value.problem {
                    InlineProblem(problem).lineLimit(1)
                } else if let resolved = value.resolved {
                    Text(axis.caption(resolved))
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                }
            }
            .frame(height: 14, alignment: .leading)
            HStack(spacing: GioSpacing.xs) {
                if !isNew {
                    GioButton(title: "Remove", systemImage: "trash", role: .borderless, action: onRemove)
                        .disabled(!canRemove)
                        .help(canRemove ? "Remove this preset" : "Keep at least one preset")
                }
                Spacer(minLength: GioSpacing.m)
                GioButton(title: "Cancel", shortcut: .cancelAction, action: onCancel)
                GioButton(title: isNew ? "Add" : "Done", role: .prominent, shortcut: .defaultAction, action: commit)
                    .disabled(value.resolved == nil)
            }
        }
        .padding(GioSpacing.m)
        .frame(width: 280)
    }

    private func commit() {
        if let resolved = value.resolved {
            onDone(resolved)
        }
    }
}
