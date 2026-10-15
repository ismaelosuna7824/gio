import GioCore
import SwiftUI

// MARK: - SectionIcon

/// A navy SF Symbol on a rounded tile in one of the mascot's spot colors,
/// like the landing page's workspace pills.
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
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(GioColor.tintFill(tint))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(GioBrand.onSpot.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(GioBrand.onSpot)
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
        case .ok: return GioColor.okInk
        case .warning: return GioColor.warningInk
        case .error: return GioColor.errorInk
        case .info: return GioColor.infoInk
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

/// One key, like the landing page's `<kbd>`: a raised cap with a hairline
/// and a 1 pt drop of the same hairline, legible in both appearances.
public struct Keycap: View {
    let glyph: KeycapGlyph

    public init(_ glyph: KeycapGlyph) {
        self.glyph = glyph
    }

    public init(_ text: String) {
        self.glyph = KeycapGlyph(text: text, role: text.count > 1 ? .wideKey : .key)
    }

    public var body: some View {
        Text(glyph.text)
            .font(glyph.role == .wideKey ? GioFont.caption.weight(.medium) : GioFont.keycap)
            .foregroundStyle(GioColor.primaryText)
            .padding(.horizontal, glyph.role == .wideKey ? 6 : 0)
            .frame(minWidth: 22, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(GioColor.raised)
                    .shadow(color: GioColor.hairline, radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(GioColor.hairline, lineWidth: 0.5)
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

private struct GioPageSectionKey: EnvironmentKey {
    static let defaultValue: MainSection? = nil
}

extension EnvironmentValues {
    /// Lay pages out without a `ScrollView` (NSScrollView-backed, so it does
    /// not render through `ImageRenderer`). Snapshot tests only.
    public var gioStaticPage: Bool {
        get { self[GioStaticPageKey.self] }
        set { self[GioStaticPageKey.self] = newValue }
    }

    /// The sidebar section a page belongs to: its header shows the
    /// section's number pill. Nil (sheets, previews) shows the title alone.
    public var gioPageSection: MainSection? {
        get { self[GioPageSectionKey.self] }
        set { self[GioPageSectionKey.self] = newValue }
    }
}

/// A section's number on its spot color, like a workspace pill in the menu
/// bar (`1 · Code`) and the landing page's section labels.
public struct SectionNumberPill: View {
    let section: MainSection
    let size: CGFloat

    public init(_ section: MainSection, size: CGFloat = 26) {
        self.section = section
        self.size = size
    }

    public var body: some View {
        Text("\(sectionNumber(section))")
            .font(.system(size: size * 0.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(GioBrand.onSpot)
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(GioColor.tintFill(sectionStyle(section).tint))
            )
            .accessibilityHidden(true)
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
    @Environment(\.gioPageSection) private var section

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
        // Switches, sliders and links take the mascot's mint.
        .tint(GioColor.accent)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xl) {
            HStack(alignment: .firstTextBaseline, spacing: GioSpacing.m) {
                VStack(alignment: .leading, spacing: GioSpacing.xxs) {
                    HStack(alignment: .center, spacing: GioSpacing.s - 2) {
                        if let section {
                            SectionNumberPill(section)
                        }
                        Text(title).font(GioFont.pageTitle).foregroundStyle(GioColor.primaryText)
                    }
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
