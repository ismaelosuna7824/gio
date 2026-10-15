import AppKit
import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of DD-05 onboarding, the status glyph and the launcher
/// (opt-in, see `SnapshotHarness`). Behind-window vibrancy and the real
/// menu do not render offscreen; the launcher uses its static backdrop.
@MainActor
final class ShellSnapshotTests: XCTestCase {
    private func page<V: View>(_ view: V) -> some View {
        view
            .environment(\.gioStaticPage, true)
            .environment(\.gioAccent, GioBrand.accent)
    }

    private func onboarding(
        _ name: String, step: OnboardingStep, ax: Bool, sr: Bool = false, loginItem: LoginItemPresentation? = nil
    ) throws {
        try SnapshotHarness.render(name, size: CGSize(width: 560, height: 520)) {
            page(OnboardingContent(accessibilityGranted: ax, screenRecordingGranted: sr, step: step, loginItem: loginItem))
        }
    }

    func testOnboardingWelcome() throws {
        try onboarding("dd05-onboarding-welcome", step: .welcome, ax: false)
    }

    func testOnboardingAccessibilityWaiting() throws {
        try onboarding("dd05-onboarding-ax-waiting", step: .accessibility, ax: false)
    }

    func testOnboardingAccessibilityGranted() throws {
        try onboarding("dd05-onboarding-ax-granted", step: .accessibility, ax: true)
    }

    func testOnboardingScreenRecording() throws {
        try onboarding("dd05-onboarding-screen-recording", step: .screenRecording, ax: true)
    }

    func testOnboardingKeys() throws {
        try onboarding(
            "dd05-onboarding-keys", step: .keys, ax: true, sr: true,
            loginItem: loginItemPresentation(status: .disabled, error: nil)
        )
    }

    func testStatusGlyphs() throws {
        let badges: [String?] = [nil, "1", "2", "9", "12"]
        try SnapshotHarness.render("dd05-status-glyph", size: CGSize(width: 460, height: 90)) {
            HStack(spacing: 22) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    let image = statusItemImage(badge: badge)
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .foregroundStyle(GioColor.primaryText)
                        .frame(width: image.size.width * 2, height: image.size.height * 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GioColor.page)
        }
    }

    private func launcherModel(_ text: String) -> LauncherViewModel {
        let windows = [
            WindowFact(id: "901:1", application: "Safari", title: "Apple Developer Documentation", workspace: 2,
                       mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: true),
            WindowFact(id: "902:1", application: "Terminal", title: "~/gio — zsh", workspace: 1,
                       mode: .tiled, floatReason: nil, isMinimized: false, workspaceIsShown: false),
        ]
        let apps: [LauncherEntry] = [
            ("Safari", "/Applications/Safari.app"), ("Notes", "/System/Applications/Notes.app"),
            ("System Settings", "/System/Applications/System Settings.app"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("Music", "/System/Applications/Music.app"), ("Calendar", "/System/Applications/Calendar.app"),
        ].map { .app(name: $0.0, bundleID: nil, path: $0.1) }
        let model = LauncherViewModel(windows: windows, apps: apps)
        model.text = text
        return model
    }

    func testLauncherEmptyQuery() throws {
        let model = launcherModel("")
        model.handle(.down)
        try SnapshotHarness.render("dd05-launcher", size: CGSize(width: 700, height: 540)) {
            page(GioLauncherView(model: model).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(PreviewDesktop()))
        }
    }

    func testLauncherWithoutIcons() throws {
        let model = launcherModel("")
        model.handle(.down)
        try SnapshotHarness.render("dd05-launcher-symbols", size: CGSize(width: 700, height: 540)) {
            page(GioLauncherView(model: model, icon: { _ in nil }).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(PreviewDesktop()))
        }
    }

    func testLauncherSearch() throws {
        try SnapshotHarness.render("dd05-launcher-search", size: CGSize(width: 700, height: 300)) {
            page(GioLauncherView(model: launcherModel("sa")).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(PreviewDesktop()))
        }
    }

    func testLauncherCommand() throws {
        try SnapshotHarness.render("dd05-launcher-command", size: CGSize(width: 700, height: 220)) {
            page(GioLauncherView(model: launcherModel("> workspace 2")).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(PreviewDesktop()))
        }
    }

    func testOverviewSetupGuideButton() throws {
        try SnapshotHarness.render("dd05-overview-guide", size: CGSize(width: 820, height: 300)) {
            page(OverviewDashboard(
                facts: OverviewFixture.facts(accessibility: true, screenRecording: true), config: OverviewFixture.config,
                showGuide: {}
            ))
        }
    }
}
