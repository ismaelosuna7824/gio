import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of NW-04 (opt-in, see `SnapshotHarness`): named workspaces
/// in the Overview and the launcher. The NSMenu does not render offscreen;
/// its row images are drawn on their own.
@MainActor
final class NamedWorkspaceSnapshotTests: XCTestCase {
    private static let stack = [
        WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: false, name: "Code",
                       icon: "chevron.left.forwardslash.chevron.right", color: "#5e9eff"),
        WorkspaceEntry(index: 2, windows: 5, columns: 4, isActive: true, name: "Browsers", icon: "globe", color: "#34c3a0"),
        WorkspaceEntry(index: 3, windows: 1, columns: 1, isActive: false, name: "Chat",
                       icon: "bubble.left.and.bubble.right.fill", color: "#a77bff"),
        WorkspaceEntry(index: 4, windows: 1, columns: 1, isActive: false),
        WorkspaceEntry(index: 5, windows: 0, columns: 0, isActive: false),
    ]

    private func namedFacts() -> SessionFacts {
        let base = OverviewFixture.facts(accessibility: true, screenRecording: true)
        return SessionFacts(
            configPath: base.configPath, configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 2, displays: [DisplayFact(id: 1, workspace: 2, stack: Self.stack)],
            windows: base.windows, screenRecordingGranted: true, strip: base.strip
        )
    }

    func testOverviewWithNamedWorkspaces() throws {
        try SnapshotHarness.render("nw04-overview", size: CGSize(width: 820, height: 1640)) {
            OverviewDashboard(facts: namedFacts(), config: OverviewFixture.config)
                .environment(\.gioStaticPage, true)
        }
    }

    func testLauncherFindsAWorkspace() throws {
        let apps: [LauncherEntry] = [
            .app(name: "Code", bundleID: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app"),
            .app(name: "Calendar", bundleID: "com.apple.iCal", path: "/System/Applications/Calendar.app"),
        ]
        let windows = [
            WindowFact(id: "901:1", application: "Code", title: "main.swift — gio", workspace: 1,
                       mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: false),
        ]
        let model = LauncherViewModel(
            windows: windows, workspaces: launcherWorkspaceEntries(from: namedFacts()), apps: apps
        )
        model.text = "c"
        try SnapshotHarness.render("nw04-launcher", size: CGSize(width: 700, height: 420)) {
            GioLauncherView(model: model)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(PreviewDesktop())
                .environment(\.gioStaticPage, true)
        }
    }

    func testMenuRowImages() throws {
        let rows = barMenuModel(BarSessionState(
            workspace: 2, windows: 9, columns: 4,
            stacks: [BarStack(display: 1, focused: true, workspaces: Self.stack)]
        )).sections[0].rows
        try SnapshotHarness.render("nw04-menu-rows", size: CGSize(width: 300, height: 170)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.index) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .opacity(row.isChecked ? 1 : 0)
                        Image(nsImage: workspaceMenuImage(symbol: row.symbol, color: row.color, index: row.index))
                            .opacity(row.symbol == nil && row.color == nil ? 0 : 1)
                        Text(row.title).font(.system(size: 13))
                        Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GioColor.page)
        }
    }
}
