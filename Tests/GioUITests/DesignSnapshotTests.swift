import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of the design system components (opt-in, see
/// `SnapshotHarness`).
@MainActor
final class DesignSnapshotTests: XCTestCase {
    func testComponentGallery() throws {
        try SnapshotHarness.render("dd01-components", size: CGSize(width: 760, height: 620)) {
            ComponentGallery()
        }
    }
}

private struct ComponentGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.xl) {
            HStack(spacing: GioSpacing.s) {
                ForEach(MainSection.allCases) { section in
                    VStack(spacing: GioSpacing.xxs) {
                        SectionIcon(section, size: 28)
                        Text(section.title).font(GioFont.caption).foregroundStyle(GioColor.secondaryText)
                    }
                    .frame(width: 78)
                }
            }
            HStack(spacing: GioSpacing.xs) {
                StatusBadge(.ok, "Granted")
                StatusBadge(.warning, "Relaunch needed")
                StatusBadge(.error, "Missing")
                StatusBadge(.neutral, "Unknown")
            }
            HStack(spacing: GioSpacing.l) {
                KeyCombo(HotkeyCombo(modifiers: [.alt, .shift], key: "H"))
                KeyCombo(HotkeyCombo(modifiers: [.cmd, .ctrl], key: "Left"))
                KeyCombo(HotkeyCombo(modifiers: [.alt], key: "Space"))
                KeyCombo(HotkeyCombo(modifiers: [.alt, .shift, .ctrl, .cmd], key: "F12"))
            }
            HStack(spacing: GioSpacing.s) {
                MetricTile("Workspaces", value: "2 / 3", detail: "Display 1", symbol: "square.stack.3d.up.fill", tint: .indigo)
                MetricTile("Windows", value: "8", detail: "5 tiled · 1 floating", symbol: "macwindow.on.rectangle", tint: .blue)
                MetricTile("Focused", value: "Safari", detail: "Workspace 2", symbol: "scope", tint: .orange)
            }
            HStack(alignment: .top, spacing: GioSpacing.s) {
                SectionCard("Permissions", footer: "Gio needs Accessibility to move windows.") {
                    CardRow {
                        HStack {
                            Text("Accessibility").font(GioFont.body)
                            Spacer()
                            StatusBadge(.ok, "Granted")
                        }
                    }
                    CardRow(divider: false) {
                        HStack {
                            Text("Screen Recording").font(GioFont.body)
                            Spacer()
                            StatusBadge(.error, "Missing")
                        }
                    }
                }
                SectionCard("Preview") {
                    PreviewCanvas(height: 110) {
                        HStack(spacing: 6) {
                            ForEach(0..<3) { index in
                                RoundedRectangle(cornerRadius: 5).fill(GioColor.card)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(index == 1 ? Color(theme: FocusRingSectionConfig.defaultColor) : GioColor.hairline, lineWidth: index == 1 ? 2 : 0.5)
                                    )
                                    .frame(width: index == 1 ? 110 : 70)
                            }
                        }
                        .padding(12)
                    }
                    .padding(GioSpacing.s)
                }
            }
        }
        .padding(GioSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GioColor.page)
    }
}
