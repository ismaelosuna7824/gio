import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of the NW-03 Workspaces section (opt-in, see
/// `SnapshotHarness`). Sheets and popovers do not render through
/// `ImageRenderer`, so the app picker and icon picker render on their own.
@MainActor
final class WorkspacesSnapshotTests: XCTestCase {
    private let pageSize = CGSize(width: 820, height: 1120)

    private func model(_ config: GioConfig, displays: Int = 1) -> DesktopModel {
        let facts = SessionFacts(
            configPath: "~/.config/gio/config.toml", configExists: true, configMessages: [],
            accessibilityGranted: true, currentWorkspace: 1,
            displays: (0..<displays).map { DisplayFact(id: UInt32($0 + 1), workspace: 1) }, windows: []
        )
        return DesktopModel(fetch: { SessionSnapshot(facts: facts, config: config) })
    }

    private func page<V: View>(_ view: V) -> some View {
        view
            .environment(\.gioStaticPage, true)
            .environment(\.gioAccent, GioBrand.accent)
    }

    func testWorkspacesList() throws {
        try SnapshotHarness.render("nw03-workspaces", size: pageSize) {
            page(WorkspacesSettingsView(model: model(WorkspacesFixture.config, displays: 2)))
        }
    }

    func testWorkspacesDirtyWithProblem() throws {
        var draft = WorkspacesDraft(config: WorkspacesFixture.config)
        draft.rename(draft.cards[2].id, to: "code")
        let chat = draft.addWorkspace(template: .design)
        draft.assign([WorkspaceAppAssignment(app: "Figma", bundleID: "com.figma.Desktop")], to: chat)
        try SnapshotHarness.render("nw03-workspaces-dirty", size: CGSize(width: 820, height: 1320)) {
            page(WorkspacesSettingsView(model: model(WorkspacesFixture.config), editing: draft))
        }
    }

    func testWorkspacesEmpty() throws {
        try SnapshotHarness.render("nw03-workspaces-empty", size: CGSize(width: 820, height: 640)) {
            page(WorkspacesSettingsView(model: model(GioConfig())))
        }
    }

    func testAppPicker() throws {
        let draft = WorkspacesDraft(config: WorkspacesFixture.config)
        try SnapshotHarness.render("nw03-app-picker", size: CGSize(width: 520, height: 580)) {
            page(
                WorkspaceAppPicker(
                    card: draft.cards[1], draft: draft, candidates: WorkspacesFixture.candidates,
                    selection: ["com.google.Chrome", "com.apple.Terminal"], onAdd: { _ in }, onCancel: {}
                )
            )
        }
    }

    func testSymbolPicker() throws {
        try SnapshotHarness.render("nw03-symbol-picker", size: CGSize(width: 360, height: 400)) {
            page(
                WorkspaceSymbolPicker(selection: .constant("globe"), color: "#34c3a0")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(GioColor.page)
            )
        }
    }

    func testSidebarWithWorkspaces() throws {
        try SnapshotHarness.render("nw03-sidebar", size: CGSize(width: 220, height: 560)) {
            SidebarReplica(status: sessionStatus(nil), selected: .workspaces, dirty: [.workspaces])
        }
    }
}

enum WorkspacesFixture {
    static let config: GioConfig = {
        let text = """
        [[workspace]]
        name = "Code"
        icon = "chevron.left.forwardslash.chevron.right"
        color = "#5e9eff"

        [[workspace]]
        name = "Browsers"
        icon = "globe"
        color = "#34c3a0"

        [[workspace]]
        name = "Chat"
        icon = "bubble.left.and.bubble.right.fill"
        color = "#a77bff"
        display = 2

        [[window-rules]]
        app = "Xcode"
        bundle-id = "com.apple.dt.Xcode"
        open-on-workspace = "Code"

        [[window-rules]]
        app = "Terminal"
        bundle-id = "com.apple.Terminal"
        open-on-workspace = "Code"
        follow = "never"

        [[window-rules]]
        app = "Safari"
        bundle-id = "com.apple.Safari"
        open-on-workspace = "Browsers"
        follow = "always"

        [[window-rules]]
        app = "Messages"
        bundle-id = "com.apple.MobileSMS"
        open-on-workspace = "Chat"

        [[window-rules]]
        app = "Mail"
        bundle-id = "com.apple.mail"
        open-on-workspace = "Chat"
        """
        guard case .success(let parsed) = parseGioConfig(text) else {
            return GioConfig()
        }
        return parsed.0
    }()

    static let candidates: [AppCandidate] = [
        AppCandidate(name: "Safari", bundleID: "com.apple.Safari", isRunning: true),
        AppCandidate(name: "Terminal", bundleID: "com.apple.Terminal", isRunning: true),
        AppCandidate(name: "Google Chrome", bundleID: "com.google.Chrome", isRunning: true),
        AppCandidate(name: "Calendar", bundleID: "com.apple.iCal"),
        AppCandidate(name: "Code", bundleID: "com.microsoft.VSCode"),
        AppCandidate(name: "Firefox", bundleID: "org.mozilla.firefox"),
        AppCandidate(name: "Notes", bundleID: "com.apple.Notes"),
        AppCandidate(name: "Preview", bundleID: "com.apple.Preview"),
    ]
}
