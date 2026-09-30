import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of the DD-02 shell and Overview (opt-in, see
/// `SnapshotHarness`). NSTableView-backed `List` and window materials do not
/// render through `ImageRenderer`, so the sidebar is composed from the same
/// row and header views the real `List` uses.
@MainActor
final class OverviewSnapshotTests: XCTestCase {
    func testWindowComposedGranted() throws {
        try SnapshotHarness.render("dd02-window", size: CGSize(width: 1040, height: 700)) {
            ComposedWindow(facts: OverviewFixture.facts(accessibility: true, screenRecording: true))
        }
    }

    func testOverviewFullPageGranted() throws {
        try SnapshotHarness.render("dd02-overview-full", size: CGSize(width: 820, height: 1560)) {
            OverviewDashboard(facts: OverviewFixture.facts(accessibility: true, screenRecording: true), config: OverviewFixture.config)
                .environment(\.gioStaticPage, true)
        }
    }

    func testOverviewPermissionsMissing() throws {
        try SnapshotHarness.render("dd02-overview-missing", size: CGSize(width: 820, height: 1640)) {
            OverviewDashboard(facts: OverviewFixture.facts(accessibility: false, screenRecording: false), config: OverviewFixture.config)
                .environment(\.gioStaticPage, true)
        }
    }

    func testOverviewWaiting() throws {
        try SnapshotHarness.render("dd02-overview-waiting", size: CGSize(width: 1040, height: 700)) {
            ComposedWindow(facts: nil)
        }
    }
}

/// Sidebar + detail as the window lays them out.
private struct ComposedWindow: View {
    let facts: SessionFacts?

    var body: some View {
        HStack(spacing: 0) {
            SidebarReplica(status: sessionStatus(facts), selected: .overview)
                .frame(width: 220)
            Divider()
            // The window scrolls; the snapshot shows the top of the page.
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .top) {
                    OverviewDashboard(facts: facts, config: OverviewFixture.config)
                        .environment(\.gioStaticPage, true)
                }
                .clipped()
        }
    }
}

private struct SidebarReplica: View {
    let status: SessionStatus
    let selected: MainSection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44) // titlebar / traffic lights
            SidebarHeader(status: status, version: "0.1.0-alpha")
            ForEach(sidebarGroups) { group in
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GioColor.tertiaryText)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                ForEach(group.sections) { section in
                    SidebarRow(section: section)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(section == selected ? Color.primary.opacity(0.1) : .clear)
                        )
                        .padding(.horizontal, 10)
                }
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
        // Stand-in for the sidebar material (not renderable offscreen).
        .background(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
    }
}

enum OverviewFixture {
    static let config = GioConfig()

    static func facts(accessibility: Bool, screenRecording: Bool) -> SessionFacts {
        let windows = [
            window(1, "Mail", "Inbox — 3 unread", workspace: 2),
            window(2, "Safari", "Apple Developer Documentation", workspace: 2),
            window(3, "Terminal", "~/gio — zsh", workspace: 2),
            window(4, "Notes", "Design ideas", workspace: 2),
            window(5, "Xcode", "Gio — SessionHost.swift", workspace: 2),
            window(6, "Finder", "Downloads Info", workspace: nil, mode: .floating, reason: .notResizable),
            window(7, "Music", "Now Playing", workspace: 1, shown: false),
            window(8, "Slack", "#gio-dev", workspace: 1, shown: false),
            window(9, "Messages", "Ana", workspace: 3, minimized: true, shown: false),
        ]
        func tile(_ id: Int, _ app: String, top: CGFloat = 8, height: CGFloat = 1069) -> StripWindowFact {
            StripWindowFact(id: "\(99_900 + id):1", application: app, top: top, height: height)
        }
        let strip = WorkspaceStripFact(
            displayID: 1, workspace: 2, viewportWidth: 1728, viewportHeight: 1085, viewportOffset: 788,
            contentWidth: 3524,
            columns: [
                StripColumnFact(x: 8, width: 780, windows: [tile(1, "Mail")]),
                StripColumnFact(x: 796, width: 1000, windows: [tile(2, "Safari")]),
                StripColumnFact(x: 1804, width: 704, windows: [
                    tile(3, "Terminal", height: 640), tile(4, "Notes", top: 656, height: 421),
                ]),
                StripColumnFact(x: 2516, width: 1000, windows: [tile(5, "Xcode")]),
            ],
            focusedColumn: 1, focusedWindowID: "99902:1"
        )
        return SessionFacts(
            configPath: "~/.config/gio/config.toml", configExists: true, configMessages: [],
            accessibilityGranted: accessibility, currentWorkspace: 2,
            displays: [DisplayFact(id: 1, workspace: 2, stack: [
                WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: false),
                WorkspaceEntry(index: 2, windows: 5, columns: 4, isActive: true),
                WorkspaceEntry(index: 3, windows: 1, columns: 1, isActive: false),
                WorkspaceEntry(index: 4, windows: 0, columns: 0, isActive: false),
            ])],
            windows: windows, screenRecordingGranted: screenRecording, strip: strip
        )
    }

    private static func window(
        _ id: Int, _ app: String, _ title: String, workspace: Int?, mode: WindowMode = .tiled,
        reason: FloatReason? = nil, minimized: Bool = false, shown: Bool = true
    ) -> WindowFact {
        WindowFact(
            id: "\(99_900 + id):1", application: app, title: title, workspace: workspace, mode: mode,
            floatReason: reason, isMinimized: minimized, workspaceIsShown: shown
        )
    }
}
