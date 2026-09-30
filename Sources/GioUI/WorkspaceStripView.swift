import AppKit
import GioCore
import SwiftUI

/// The running app's icon for a `WindowFact.id` (`pid:element`), looked up
/// on main through `NSRunningApplication`; nil for unknown processes.
@MainActor
func runningAppIcon(windowID: String) -> NSImage? {
    guard let pidText = windowID.split(separator: ":").first, let pid = Int32(pidText), pid > 0 else {
        return nil
    }
    return NSRunningApplication(processIdentifier: pid)?.icon
}

/// App icon, or the app's initials on a soft tile when no icon is known.
struct AppIconView: View {
    let windowID: String
    let application: String
    var size: CGFloat = 20

    var body: some View {
        if let icon = runningAppIcon(windowID: windowID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            InitialsTile(initials: appInitials(application), size: size)
        }
    }
}

/// A stable pastel tint per app name so the same app always looks the same.
func appTint(_ application: String) -> SectionTint {
    let tints: [SectionTint] = [.blue, .indigo, .purple, .pink, .orange, .green, .teal]
    let sum = application.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return tints[sum % tints.count]
}

struct InitialsTile: View {
    let initials: String
    var size: CGFloat = 20
    var tint: SectionTint?

    var body: some View {
        let color = GioColor.tint(tint ?? appTint(initials))
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.opacity(0.18))
            .overlay(
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.38 : 0.48), weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// DD-02 live miniature of the current workspace strip: columns to scale,
/// the display's viewport frame, the focused column in the accent, parked
/// columns faded.
struct WorkspaceStripView: View {
    let miniature: WorkspaceMiniature
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 14
            let available = CGSize(width: proxy.size.width - inset * 2, height: proxy.size.height - inset * 2)
            let fitted = fit(aspect: miniature.aspectRatio, in: available)
            let origin = CGPoint(
                x: inset + (available.width - fitted.width) / 2,
                y: inset + (available.height - fitted.height) / 2
            )
            let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
            ZStack(alignment: .topLeading) {
                viewportFrame(in: fitted, origin: origin)
                ForEach(miniature.tiles) { tile in
                    tileView(tile, palette: palette, rect: scaled(tile.rect, fitted, origin, gap: 1.5))
                }
                viewportOutline(in: fitted, origin: origin)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let columns = Set(miniature.tiles.map(\.column)).count
        let parked = Set(miniature.tiles.filter(\.isParked).map(\.column)).count
        return "Workspace strip: \(columns) columns, \(parked) parked off screen"
    }

    private func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else {
            return .zero
        }
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    private func scaled(_ unit: CGRect, _ size: CGSize, _ origin: CGPoint, gap: CGFloat = 0) -> CGRect {
        CGRect(
            x: origin.x + unit.minX * size.width, y: origin.y + unit.minY * size.height,
            width: unit.width * size.width, height: unit.height * size.height
        ).insetBy(dx: gap, dy: gap)
    }

    /// The "screen": a lifted surface behind the visible part of the strip.
    private func viewportFrame(in size: CGSize, origin: CGPoint) -> some View {
        let rect = scaled(miniature.viewport, size, origin).insetBy(dx: -4, dy: -4)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(GioColor.page.opacity(colorScheme == .dark ? 0.55 : 0.9))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func viewportOutline(in size: CGSize, origin: CGPoint) -> some View {
        let rect = scaled(miniature.viewport, size, origin).insetBy(dx: -4, dy: -4)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(GioColor.secondaryText.opacity(0.55), lineWidth: 1.25)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func tileView(_ tile: MiniatureTile, palette: AccentPalette, rect: CGRect) -> some View {
        let focusedColumn = tile.isFocusedColumn && !tile.isParked
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tile.isFocusedWindow ? palette.fill.opacity(0.28) : GioColor.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        focusedColumn ? palette.fill : GioColor.hairline,
                        lineWidth: tile.isFocusedWindow ? 2 : (focusedColumn ? 1.25 : 0.5)
                    )
            )
            .overlay(tileLabel(tile, rect: rect))
            .shadow(color: .black.opacity(tile.isParked ? 0 : 0.08), radius: 1, y: 0.5)
            .opacity(tile.isParked ? 0.38 : 1)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private func tileLabel(_ tile: MiniatureTile, rect: CGRect) -> some View {
        let iconSize = min(22, rect.width * 0.4, rect.height * 0.42)
        if iconSize >= 10 {
            VStack(spacing: 3) {
                AppIconView(windowID: tile.id, application: tile.application, size: iconSize)
                if rect.width >= 64, rect.height >= 50 {
                    Text(tile.application)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(GioColor.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}
