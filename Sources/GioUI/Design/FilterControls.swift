import SwiftUI

/// DD-04 filter vocabulary shared by Shortcuts and Logs: a prominent search
/// field and capsule chips. Pure SwiftUI (no AppKit-backed controls except
/// the live text field), so they render in snapshots too.

/// Search field with a magnifier, a clear button and an optional shortcut
/// hint ("⌘F"). The live field is a real `TextField` that `focus` drives.
struct GioSearchField: View {
    let prompt: String
    @Binding var text: String
    var hint: String?
    var large = true
    var focus: FocusState<Bool>.Binding?
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: GioSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 14 : 12, weight: .medium))
                .foregroundStyle(GioColor.secondaryText)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(GioColor.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else if let hint {
                Text(hint)
                    .font(GioFont.caption.weight(.medium))
                    .foregroundStyle(GioColor.tertiaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(GioColor.hairline))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, GioSpacing.s - 2)
        .frame(height: large ? 34 : 28)
        .background(
            RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(colorScheme == .dark ? 0.9 : 0.8), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 1, y: 0.5)
    }

    @ViewBuilder
    private var field: some View {
        let font = large ? Font.system(size: 14) : GioFont.body
        if isStatic {
            Text(text.isEmpty ? prompt : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? GioColor.tertiaryText : GioColor.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let focus {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .focused(focus)
                .accessibilityLabel(prompt)
        } else {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .accessibilityLabel(prompt)
        }
    }
}

/// A selectable capsule with an optional count and leading dot.
struct FilterChip: View {
    let title: String
    var count: Int?
    var dot: Color?
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(title).font(GioFont.callout.weight(isSelected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(GioFont.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? palette.onFill.opacity(0.75) : GioColor.tertiaryText)
                }
            }
            .foregroundStyle(isSelected ? palette.onFill : GioColor.primaryText)
            .padding(.horizontal, GioSpacing.s - 2)
            .frame(height: 26)
            .background(Capsule().fill(isSelected ? palette.fill : GioColor.card))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : GioColor.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

/// A small inline tag ("config", "×3").
struct InlineTag: View {
    let text: String
    var tint: Color = GioColor.secondaryText
    var ink: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink ?? tint)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }
}

/// Centered empty state inside a card.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    let actions: Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: GioSpacing.s - 2) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(GioColor.tertiaryText)
            Text(title).font(GioFont.headline)
            Text(message)
                .font(GioFont.callout)
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions.padding(.top, GioSpacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GioSpacing.xxl + 8)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message, actions: { EmptyView() })
    }
}
