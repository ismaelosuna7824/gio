import GioCore
import SwiftUI

/// Native controls for the settings sections. AppKit-backed controls do not
/// draw through `ImageRenderer`, so on a static page (snapshot tests only,
/// `gioStaticPage`) each one draws a same-size SwiftUI replica instead. The
/// live app always gets the native control.

private struct ReplicaMetrics {
    static let height: CGFloat = 22
    static let radius: CGFloat = 6
}

private struct ReplicaSurface: View {
    var radius: CGFloat = ReplicaMetrics.radius
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 0.5, y: 0.5)
    }
}

struct GioSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var width: CGFloat
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if isStatic {
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let selected = option.0 == selection
                    Text(option.1)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? (colorScheme == .dark ? Color.white.opacity(0.26) : Color.white) : .clear)
                                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 0.5, y: 0.5)
                                .padding(1.5)
                        )
                        .overlay(alignment: .leading) {
                            if index > 0, option.0 != selection, options[index - 1].0 != selection {
                                Rectangle().fill(GioColor.hairline).frame(width: 1, height: 12)
                            }
                        }
                }
            }
            .frame(width: width, height: ReplicaMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: ReplicaMetrics.radius, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
            )
            .opacity(isEnabled ? 1 : 0.45)
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: width)
            .accessibilityLabel(title)
        }
    }
}

struct GioSwitch: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if isStatic {
            Capsule()
                .fill(isOn ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.12))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                        .padding(1.5)
                }
                .frame(width: 32, height: 18)
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

struct GioSlider: View {
    let title: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if isStatic {
            GeometryReader { proxy in
                let span = range.upperBound - range.lowerBound
                let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
                let knob: CGFloat = 16
                let x = (proxy.size.width - knob) * CGFloat(fraction)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    Capsule().fill(Color(nsColor: .controlAccentColor)).frame(width: x + knob / 2, height: 4)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                        .frame(width: knob, height: knob)
                        .offset(x: x)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            .opacity(isEnabled ? 1 : 0.45)
        } else {
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
        }
    }
}

struct GioTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var width: CGFloat
    var monospaced = false
    var alignment: TextAlignment = .leading
    @Environment(\.gioStaticPage) private var isStatic

    var body: some View {
        if isStatic {
            Text(text.isEmpty ? prompt : text)
                .font(monospaced ? GioFont.callout.monospaced() : GioFont.body)
                .foregroundStyle(text.isEmpty ? GioColor.tertiaryText : GioColor.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: width, height: ReplicaMetrics.height, alignment: alignment == .trailing ? .trailing : .leading)
                .background(ReplicaSurface(radius: 5))
        } else {
            TextField(title, text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? GioFont.callout.monospaced() : GioFont.body)
                .multilineTextAlignment(alignment)
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }
}

/// Pop-up menu picker.
struct GioPopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var width: CGFloat
    @Environment(\.gioStaticPage) private var isStatic

    var body: some View {
        if isStatic {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(GioFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GioColor.secondaryText)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: ReplicaMetrics.height)
            .background(ReplicaSurface())
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(width: width)
            .accessibilityLabel(title)
        }
    }
}

enum GioButtonRole {
    case normal, prominent, borderless
}

struct GioButton: View {
    let title: String
    var systemImage: String?
    var role: GioButtonRole = .normal
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if isStatic {
            replica
        } else {
            native
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            }
            Text(title)
        }
    }

    @ViewBuilder
    private var native: some View {
        let button = Button(action: action) { label }
            .keyboardShortcut(shortcut)
        switch role {
        case .normal: button
        case .prominent: button.buttonStyle(.borderedProminent)
        case .borderless: button.buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var replica: some View {
        switch role {
        case .borderless:
            label.font(GioFont.body).foregroundStyle(Color(nsColor: .linkColor))
                .opacity(isEnabled ? 1 : 0.4)
        case .normal, .prominent:
            label
                .font(GioFont.body.weight(role == .prominent ? .medium : .regular))
                .foregroundStyle(role == .prominent ? Color.white : GioColor.primaryText)
                .padding(.horizontal, 10)
                .frame(height: ReplicaMetrics.height)
                .background {
                    if role == .prominent {
                        RoundedRectangle(cornerRadius: ReplicaMetrics.radius, style: .continuous)
                            .fill(Color(nsColor: .controlAccentColor))
                    } else {
                        ReplicaSurface()
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Native color well; a swatch well on a static page.
struct GioColorWell: View {
    let title: String
    @Binding var color: Color
    @Environment(\.gioStaticPage) private var isStatic

    var body: some View {
        if isStatic {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .padding(3)
                .frame(width: 38, height: ReplicaMetrics.height)
                .background(ReplicaSurface())
        } else {
            ColorPicker(title, selection: $color, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

/// A borderless icon menu (row actions).
struct GioIconMenu<Items: View>: View {
    let title: String
    let systemImage: String
    let items: Items
    @Environment(\.gioStaticPage) private var isStatic

    init(_ title: String, systemImage: String, @ViewBuilder items: () -> Items) {
        self.title = title
        self.systemImage = systemImage
        self.items = items()
    }

    var body: some View {
        if isStatic {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(GioColor.secondaryText)
        } else {
            Menu {
                items
            } label: {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(GioColor.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(title)
            .accessibilityLabel(title)
        }
    }
}
