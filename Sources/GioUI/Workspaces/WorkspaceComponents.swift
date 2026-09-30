import AppKit
import GioCore
import SwiftUI

/// NW-03 building blocks shared by the Workspaces section, the Overview,
/// the menu bar and the launcher.

/// A named workspace's mark: its SF Symbol, white or black for contrast,
/// on a rounded tile of its color (neutral gray without one).
struct WorkspaceGlyph: View {
    let icon: String?
    let color: String?
    var size: CGFloat = 28
    /// Shown when there is no icon (the workspace's index, or initials).
    var fallback: String = ""

    private var theme: ThemeColor {
        color.flatMap(ThemeColor.init(hex:)) ?? ThemeColor(red: 0.56, green: 0.56, blue: 0.58)
    }

    var body: some View {
        let stops = accentGradientStops(theme)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: stops.map { Color(theme: $0) }, startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(glyph.foregroundStyle(Color(theme: workspaceGlyphForeground(theme))))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let icon, !icon.isEmpty {
            Image(systemName: icon).font(.system(size: size * 0.5, weight: .semibold))
        } else {
            Text(fallback)
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// White like System Settings tiles; black only on very light colors
/// (yellow), where a white symbol would wash out.
func workspaceGlyphForeground(_ color: ThemeColor) -> ThemeColor {
    let white = ThemeColor(red: 1, green: 1, blue: 1)
    return contrastRatio(white, color) >= 2 ? white : ThemeColor(red: 0, green: 0, blue: 0)
}

/// Lays children out left to right, wrapping to new rows (app chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.indices.isEmpty ? size.width : size.width + spacing
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A round preset color with a selection ring (focus ring and workspace
/// color rows).
struct ColorSwatchButton: View {
    let color: ThemeColor
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(theme: color))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .overlay(
                    Circle().strokeBorder(GioColor.primaryText.opacity(0.75), lineWidth: 1.5)
                        .padding(-3.5)
                        .opacity(isSelected ? 1 : 0)
                )
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension AppIconResolver {
    /// Icon for an app by bundle id (installed location), else by name.
    static func icon(bundleID: String?, name: String) -> CGImage? {
        guard let bundleID, !bundleID.isEmpty else {
            return icon(named: name)
        }
        let key = "bundle:\(bundleID)"
        if let cached = cachedIcon(key) {
            return cached
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let raster = url.map { NSWorkspace.shared.icon(forFile: $0.path) }.flatMap(rasterizeIcon) ?? icon(named: name)
        storeIcon(raster, for: key)
        return raster
    }
}

/// App icon by bundle id and name; initials when neither resolves.
struct BundleAppIcon: View {
    let name: String
    var bundleID: String?
    var size: CGFloat = 20

    var body: some View {
        if let icon = AppIconResolver.icon(bundleID: bundleID, name: name) {
            Image(decorative: icon, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            InitialsTile(initials: appInitials(name), size: size * 0.86)
                .frame(width: size, height: size)
        }
    }
}
