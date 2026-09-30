import AppKit
import GioCore
import SwiftUI

/// DD-03 building blocks shared by the settings sections: labeled rows,
/// slider rows with value labels, inline problems, the Apply bar and the
/// Apply toast.

// MARK: - Rows

/// Label (and optional caption) on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let caption: String?
    let control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: GioSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GioFont.body)
                if let caption {
                    Text(caption)
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

/// A switch row.
struct ToggleRow: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        _isOn = isOn
    }

    var body: some View {
        SettingRow(title, caption: caption) {
            GioSwitch(title: title, isOn: $isOn)
        }
    }
}

/// A slider with its formatted value to the right.
struct SliderRow: View {
    let title: String
    let caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(
        _ title: String, caption: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
        step: Double, format: @escaping (Double) -> String
    ) {
        self.title = title
        self.caption = caption
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        SettingRow(title, caption: caption) {
            HStack(spacing: GioSpacing.s) {
                GioSlider(title: title, valueLabel: format(value), value: $value, range: range, step: step)
                    .frame(width: 200)
                Text(format(value))
                    .font(GioFont.callout.monospacedDigit())
                    .foregroundStyle(GioColor.secondaryText)
                    .frame(width: 56, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A segmented picker row.
struct SegmentedRow<Value: Hashable>: View {
    let title: String
    let caption: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    var width: CGFloat = 240

    init(_ title: String, caption: String? = nil, selection: Binding<Value>, options: [(Value, String)], width: CGFloat = 240) {
        self.title = title
        self.caption = caption
        _selection = selection
        self.options = options
        self.width = width
    }

    var body: some View {
        SettingRow(title, caption: caption) {
            GioSegmented(title: title, selection: $selection, options: options, width: width)
        }
    }
}

/// Validation message shown right under the row it is about.
struct InlineProblem: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(GioFont.caption)
            .foregroundStyle(GioColor.ink(.systemOrange))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Reset section" in a page's header.
struct ResetSectionButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        GioButton(title: "Reset Section", systemImage: "arrow.counterclockwise", role: .borderless, action: action)
            .disabled(isDisabled)
        .help("Restore this section's defaults. Nothing changes until you apply.")
        .accessibilityHint("Restores defaults as unsaved edits")
    }
}

// MARK: - Apply bar and toast

/// Floating bar shown while a section has unsaved edits.
struct ApplyBar: View {
    let state: ApplyBarState
    let onApply: () -> Void
    let onRevert: () -> Void

    var body: some View {
        if case .visible(let canApply, let problemCount) = state {
            HStack(spacing: GioSpacing.s) {
                Image(systemName: canApply ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(canApply ? GioColor.secondaryText : GioColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unsaved changes").font(GioFont.headline)
                    Text(canApply
                        ? "Preview updates live. Apply writes config.toml and reloads."
                        : (problemCount == 1 ? "Fix 1 problem to apply." : "Fix \(problemCount) problems to apply."))
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                }
                Spacer(minLength: GioSpacing.s)
                GioButton(title: "Revert", shortcut: .cancelAction, action: onRevert)
                    .help("Discard unsaved edits (Esc)")
                GioButton(title: "Apply", role: .prominent, shortcut: KeyboardShortcut("s", modifiers: .command), action: onApply)
                    .disabled(!canApply)
                    .help("Write config.toml and reload (⌘S)")
            }
            .controlSize(.regular)
            .padding(.horizontal, GioSpacing.m)
            .padding(.vertical, GioSpacing.s - 2)
            .background(
                RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                    .strokeBorder(GioColor.hairline.opacity(0.7), lineWidth: 0.5)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unsaved changes")
        }
    }
}

/// Apply outcome, shown briefly (success) or until dismissed (problems).
struct ApplyToastView: View {
    let toast: ApplyToast
    let onDismiss: () -> Void

    private var kind: StatusKind {
        switch toast.kind {
        case .success: return .ok
        case .warning: return .warning
        case .failure: return .error
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: GioSpacing.s - 2) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(GioFont.headline)
                ForEach(toast.details, id: \.self) { detail in
                    Text(detail)
                        .font(GioFont.mono)
                        .foregroundStyle(GioColor.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !toast.details.isEmpty {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GioColor.secondaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, GioSpacing.m - 2)
        .padding(.vertical, GioSpacing.s - 2)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.7), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Settings page chrome: the page, then the Apply bar and toast floating at
/// the bottom. Keyboard: ⌘S applies, Esc reverts (while the bar shows).
struct SettingsScaffold<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let barState: ApplyBarState
    @Binding var toast: ApplyToast?
    let onApply: () -> Void
    let onRevert: () -> Void
    let accessory: Accessory
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String, subtitle: String, barState: ApplyBarState, toast: Binding<ApplyToast?>,
        onApply: @escaping () -> Void, onRevert: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.barState = barState
        _toast = toast
        self.onApply = onApply
        self.onRevert = onRevert
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        GioPage(title, subtitle: subtitle, accessory: { accessory }) {
            content
            // Room so the floating bar never covers the last card.
            Color.clear.frame(height: barState == .hidden ? 0 : 56)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: GioSpacing.s) {
                if let toast {
                    ApplyToastView(toast: toast) { self.toast = nil }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                ApplyBar(state: barState, onApply: onApply, onRevert: onRevert)
                    .frame(maxWidth: 640)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            .padding(.horizontal, GioSpacing.xl)
            .padding(.bottom, GioSpacing.m)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: barState)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: toast)
        .task(id: toast) {
            // Success fades on its own; problems stay until dismissed.
            guard let shown = toast, shown.details.isEmpty else {
                return
            }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast == shown {
                toast = nil
            }
        }
    }
}

// MARK: - Mini window

/// A sample window for previews: a raised tile with a tiny title bar.
struct MiniWindow: View {
    var tint: SectionTint = .blue
    var title: String? = nil
    var cornerRadius: CGFloat = 5
    var showsTitleBar = true

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(GioColor.raised)
            .overlay(alignment: .top) {
                if showsTitleBar {
                    VStack(spacing: 0) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<3) { _ in
                                Circle().fill(GioColor.tertiaryText.opacity(0.6)).frame(width: 4, height: 4)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 11)
                        Rectangle().fill(GioColor.hairline.opacity(0.5)).frame(height: 0.5)
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 1.5).fill(GioColor.tint(tint).opacity(0.55)).frame(height: 4)
                                .frame(maxWidth: 48, alignment: .leading)
                            ForEach(0..<3) { index in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(GioColor.secondaryText.opacity(0.16))
                                    .frame(height: 3)
                                    .padding(.trailing, CGFloat(index) * 10)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GioColor.hairline.opacity(0.8), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
    }
}

/// A soft "desktop" behind preview windows.
struct PreviewDesktop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.16, green: 0.18, blue: 0.24), Color(red: 0.10, green: 0.11, blue: 0.15)]
                : [Color(red: 0.84, green: 0.88, blue: 0.95), Color(red: 0.76, green: 0.81, blue: 0.90)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

extension Color {
    /// The sRGB config color this SwiftUI color resolves to (color picker).
    var themeColor: ThemeColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 1)
        return ThemeColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}

func formatPoints(_ value: Double) -> String {
    "\(Int(value.rounded())) pt"
}

func formatPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
