import GioCore
import SwiftUI

// MARK: - SectionIcon

/// A white SF Symbol on a rounded-square colored tile (System Settings).
public struct SectionIcon: View {
    let symbol: String
    let tint: SectionTint
    let size: CGFloat

    public init(symbol: String, tint: SectionTint, size: CGFloat = 20) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public init(_ section: MainSection, size: CGFloat = 20) {
        let style = sectionStyle(section)
        self.init(symbol: style.symbol, tint: style.tint, size: size)
    }

    public var body: some View {
        let color = GioColor.tint(tint)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(
                colors: [color.opacity(0.82), color], startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - StatusBadge

public enum StatusKind: Equatable, Sendable {
    case ok, warning, error, info, neutral

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .ok: return GioColor.ok
        case .warning: return GioColor.warning
        case .error: return GioColor.error
        case .info: return GioColor.info
        case .neutral: return GioColor.neutral
        }
    }

    var ink: Color {
        switch self {
        case .ok: return GioColor.ink(.systemGreen)
        case .warning: return GioColor.ink(.systemOrange)
        case .error: return GioColor.ink(.systemRed)
        case .info: return GioColor.ink(.systemBlue)
        case .neutral: return GioColor.secondaryText
        }
    }
}

/// Symbol + short label in a tinted capsule.
public struct StatusBadge: View {
    let kind: StatusKind
    let label: String
    let symbol: String?

    public init(_ kind: StatusKind, _ label: String, symbol: String? = nil) {
        self.kind = kind
        self.label = label
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: GioSpacing.xxs) {
            Image(systemName: symbol ?? kind.symbol)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(GioFont.captionEmphasis)
        }
        .foregroundStyle(kind.ink)
        .padding(.horizontal, GioSpacing.xs)
        .padding(.vertical, 3)
        .background(Capsule().fill(kind.color.opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keycap

/// One key: rounded cap with a subtle bezel and a 1 pt drop, legible in
/// both appearances.
public struct Keycap: View {
    let glyph: KeycapGlyph
    @Environment(\.colorScheme) private var colorScheme

    public init(_ glyph: KeycapGlyph) {
        self.glyph = glyph
    }

    public init(_ text: String) {
        self.glyph = KeycapGlyph(text: text, role: text.count > 1 ? .wideKey : .key)
    }

    public var body: some View {
        let dark = colorScheme == .dark
        Text(glyph.text)
            .font(glyph.role == .wideKey ? GioFont.caption.weight(.medium) : GioFont.keycap)
            .foregroundStyle(GioColor.primaryText.opacity(0.85))
            .padding(.horizontal, glyph.role == .wideKey ? 6 : 0)
            .frame(minWidth: 22, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(
                        colors: dark
                            ? [Color.white.opacity(0.16), Color.white.opacity(0.10)]
                            : [Color.white, Color(nsColor: .controlBackgroundColor)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// A whole combo as a row of keycaps.
public struct KeyCombo: View {
    let combo: HotkeyCombo

    public init(_ combo: HotkeyCombo) {
        self.combo = combo
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keycapGlyphs(for: combo).enumerated()), id: \.offset) { _, glyph in
                Keycap(glyph)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.describe())
    }
}

// MARK: - SectionCard

/// A grouped container with an optional header above and footer below,
/// like a `Form` section in System Settings.
public struct SectionCard<Content: View, Accessory: View>: View {
    let title: String?
    let footer: String?
    let accessory: Accessory
    let content: Content

    public init(
        _ title: String? = nil, footer: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xs) {
            if title != nil || !(accessory is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(GioFont.sectionTitle).foregroundStyle(GioColor.primaryText)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, GioSpacing.xxs)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                    .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
            )
            if let footer {
                Text(footer)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, GioSpacing.xxs)
            }
        }
    }
}

extension SectionCard where Accessory == EmptyView {
    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// A padded row inside a `SectionCard`, with an inset divider below when
/// it is not the last one.
public struct CardRow<Content: View>: View {
    let showsDivider: Bool
    let content: Content

    public init(divider: Bool = true, @ViewBuilder content: () -> Content) {
        showsDivider = divider
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, GioSpacing.m - 2)
                .padding(.vertical, GioSpacing.s - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsDivider {
                Divider().padding(.leading, GioSpacing.m - 2)
            }
        }
    }
}

// MARK: - MetricTile

/// A big rounded numeral with a caption and optional symbol and detail.
public struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    let symbol: String?
    let tint: SectionTint

    public init(_ title: String, value: String, detail: String? = nil, symbol: String? = nil, tint: SectionTint = .blue) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xs) {
            HStack(spacing: GioSpacing.xs - 2) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GioColor.tint(tint))
                }
                Text(title)
                    .font(GioFont.captionEmphasis)
                    .foregroundStyle(GioColor.secondaryText)
                    .lineLimit(1)
            }
            Text(value)
                .font(value.count > 8 ? GioFont.metricSmall : GioFont.metric)
                .foregroundStyle(GioColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
            Text(detail ?? " ")
                .font(GioFont.caption)
                .foregroundStyle(GioColor.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GioSpacing.s + 2)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - PreviewCanvas

/// A recessed, framed canvas for live previews (the workspace miniature,
/// layout and animation previews).
public struct PreviewCanvas<Content: View>: View {
    let height: CGFloat
    let content: Content

    public init(height: CGFloat = 140, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: GioRadius.medium - 2, style: .continuous).fill(GioColor.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GioRadius.medium - 2, style: .continuous)
                    .strokeBorder(GioColor.hairline.opacity(0.5), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: GioRadius.medium - 2, style: .continuous))
    }
}

// MARK: - Page scaffold

private struct GioStaticPageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Lay pages out without a `ScrollView` (NSScrollView-backed, so it does
    /// not render through `ImageRenderer`). Snapshot tests only.
    public var gioStaticPage: Bool {
        get { self[GioStaticPageKey.self] }
        set { self[GioStaticPageKey.self] = newValue }
    }
}

/// Standard detail page: large title, optional subtitle and trailing
/// accessory (e.g. "Reset section"), scrolling content.
public struct GioPage<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory
    let content: Content
    let scrolls: Bool
    @Environment(\.gioStaticPage) private var isStatic

    /// `scrolls: false` pins the header and lets the content fill the rest
    /// (pages with their own scrolling list, like Logs).
    public init(
        _ title: String, subtitle: String? = nil, scrolls: Bool = true,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        Group {
            if !scrolls {
                column.frame(maxHeight: .infinity, alignment: .top)
            } else if isStatic {
                column
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { column }
            }
        }
        .background(GioColor.page)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xl) {
            HStack(alignment: .firstTextBaseline, spacing: GioSpacing.m) {
                VStack(alignment: .leading, spacing: GioSpacing.xxs) {
                    Text(title).font(GioFont.pageTitle)
                    if let subtitle {
                        Text(subtitle).font(GioFont.callout).foregroundStyle(GioColor.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(.horizontal, GioSpacing.xl)
        .padding(.vertical, GioSpacing.l)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension GioPage where Accessory == EmptyView {
    public init(_ title: String, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, scrolls: scrolls, accessory: { EmptyView() }, content: content)
    }
}
