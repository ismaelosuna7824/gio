import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of the DD-03 follow-ups (opt-in, see `SnapshotHarness`):
/// preset chips, the chip editor (a popover live) and the sidebar dots for
/// sections with unsaved edits.
@MainActor
final class FollowUpSnapshotTests: XCTestCase {
    private func page<V: View>(_ view: V) -> some View {
        view
            .environment(\.gioStaticPage, true)
            .environment(\.gioAccent, GioBrand.accent)
    }

    func testLayoutWithPresetChips() throws {
        var form = LayoutSettingsForm(config: SettingsFixture.config.layout)
        form.presetsText = "0.33333, 0.5, 0.66667, 800"
        try SnapshotHarness.render("dd04-layout-chips", size: CGSize(width: 820, height: 1180)) {
            page(LayoutSettingsView(model: DesktopModel(fetch: { SessionSnapshot(config: SettingsFixture.config) }), editing: form))
        }
    }

    func testPresetEditors() throws {
        try SnapshotHarness.render("dd04-preset-editor", size: CGSize(width: 640, height: 190)) {
            page(
                HStack(alignment: .top, spacing: GioSpacing.l) {
                    PresetWidthEditor(
                        value: PresetWidthEditorValue(value: 0.33333), isNew: false, canRemove: true,
                        onDone: { _ in }, onRemove: {}, onCancel: {}
                    )
                    .background(RoundedRectangle(cornerRadius: 10).fill(GioColor.raised))
                    PresetWidthEditor(
                        value: PresetWidthEditorValue(amount: "140", unit: .percent), isNew: true, canRemove: false,
                        onDone: { _ in }, onRemove: {}, onCancel: {}
                    )
                    .background(RoundedRectangle(cornerRadius: 10).fill(GioColor.raised))
                }
                .padding(GioSpacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(GioColor.page)
            )
        }
    }

    func testSidebarUnsavedDots() throws {
        try SnapshotHarness.render("dd04-sidebar-dirty", size: CGSize(width: 240, height: 560)) {
            SidebarReplica(
                status: SessionStatus(kind: .ok, label: "Running"), selected: .focus, dirty: [.layout, .focus]
            )
            .environment(\.gioAccent, GioBrand.accent)
        }
    }
}
