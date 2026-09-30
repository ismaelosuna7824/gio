import GioCore
import SwiftUI
import XCTest
@testable import GioUI

/// Visual review of the DD-03 settings sections (opt-in, see
/// `SnapshotHarness`). Sheets, menus and `ScrollView` do not render through
/// `ImageRenderer`, so pages render statically and the rule editor on its own.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private let pageSize = CGSize(width: 820, height: 1180)

    private func model(_ config: GioConfig = SettingsFixture.config) -> DesktopModel {
        DesktopModel(fetch: { SessionSnapshot(config: config) })
    }

    private func page<V: View>(_ view: V) -> some View {
        view
            .environment(\.gioStaticPage, true)
            .environment(\.gioAccent, FocusRingSectionConfig.defaultColor)
    }

    func testLayoutClean() throws {
        try SnapshotHarness.render("dd03-layout", size: pageSize) {
            page(LayoutSettingsView(model: model()))
        }
    }

    func testLayoutEditedMaximized() throws {
        var form = LayoutSettingsForm(config: SettingsFixture.config.layout)
        form.gaps = 24
        form.padding = 20
        form.fullscreenGapFollowsGaps = false
        form.fullscreenGap = 40
        try SnapshotHarness.render("dd03-layout-maximized-dirty", size: pageSize) {
            page(LayoutSettingsView(model: model(), editing: form, previewMode: .maximized))
        }
    }

    func testLayoutInvalid() throws {
        var form = LayoutSettingsForm(config: SettingsFixture.config.layout)
        form.widthKind = .points
        form.widthValue = 900
        form.presetsText = "0.5, wide"
        try SnapshotHarness.render("dd03-layout-invalid", size: pageSize) {
            page(LayoutSettingsView(model: model(), editing: form))
        }
    }

    func testAnimationsSpring() throws {
        try SnapshotHarness.render("dd03-animations", size: pageSize) {
            page(AnimationsSettingsView(model: model(), previewTime: 0.09))
        }
    }

    func testAnimationsEaseOutDirty() throws {
        var form = AnimationsForm(config: SettingsFixture.config.animations)
        form.curve = .easeOut
        form.durationMilliseconds = 320
        form.renderer = .snapshot
        try SnapshotHarness.render("dd03-animations-ease-dirty", size: pageSize) {
            page(AnimationsSettingsView(model: model(), editing: form, previewTime: 0.1))
        }
    }

    func testPerAnimationInheriting() throws {
        try SnapshotHarness.render("na04-animations-per-animation", size: CGSize(width: 820, height: 1340)) {
            page(AnimationsSettingsView(model: model(), previewTime: 0.09))
        }
    }

    func testPerAnimationCustomExpanded() throws {
        var form = AnimationsForm(config: SettingsFixture.config.animations)
        form.setCustom(.windowOpen, true)
        form.kinds[.windowOpen]?.dampingRatio = 0.7
        form.kinds[.windowOpen]?.stiffness = 500
        form.openOffset = 32
        form.setCustom(.windowMovement, true)
        form.kinds[.windowMovement]?.curve = .easeOut
        form.kinds[.windowMovement]?.durationMilliseconds = 140
        form.kinds[.workspaceSwitch]?.enabled = false
        form.closeGhost = true
        try SnapshotHarness.render("na04-animations-per-animation-custom", size: CGSize(width: 820, height: 1880)) {
            page(
                AnimationsSettingsView(
                    model: model(), editing: form, previewTime: 0.12, expandedKinds: [.windowOpen, .windowClose]
                )
            )
        }
    }

    func testAnimationsReduceMotion() throws {
        try SnapshotHarness.render("dd03-animations-reduce-motion", size: CGSize(width: 820, height: 420)) {
            page(
                MotionPreviewView(
                    parameters: AnimationsForm(config: SettingsFixture.config.animations).preview,
                    reduceMotionOverride: true
                )
                .padding(GioSpacing.xl)
            )
        }
    }

    func testFocusDim() throws {
        try SnapshotHarness.render("dd03-focus-dim", size: pageSize) {
            page(FocusSettingsView(model: model()))
        }
    }

    func testFocusRingDirty() throws {
        var draft = FocusSectionDraft(config: SettingsFixture.config)
        draft.indicator.indicator = .ring
        draft.ring.width = 6
        draft.ring.colorText = "#ffc87f"
        try SnapshotHarness.render("dd03-focus-ring", size: pageSize) {
            page(FocusSettingsView(model: model(), editing: draft))
        }
    }

    func testRulesList() throws {
        try SnapshotHarness.render("dd03-rules", size: CGSize(width: 820, height: 560)) {
            page(RulesSettingsView(model: model()))
        }
    }

    func testRulesEmpty() throws {
        var config = SettingsFixture.config
        config.rules = []
        try SnapshotHarness.render("dd03-rules-empty", size: CGSize(width: 820, height: 560)) {
            page(RulesSettingsView(model: model(config)))
        }
    }

    func testRuleEditor() throws {
        try SnapshotHarness.render("dd03-rule-editor", size: CGSize(width: 520, height: 330)) {
            page(RuleEditor(
                draft: RuleDraft(index: 0, form: RuleForm(app: "Safari", mode: .floating, workspace: 3)),
                onSave: { _ in }, onCancel: {}
            ).frame(maxHeight: .infinity).background(GioColor.page))
        }
    }

    func testRuleEditorInvalid() throws {
        try SnapshotHarness.render("dd03-rule-editor-invalid", size: CGSize(width: 520, height: 360)) {
            page(RuleEditor(
                draft: RuleDraft(index: 2, form: RuleForm(app: "", mode: nil, workspace: nil)),
                onSave: { _ in }, onCancel: {}
            ).frame(maxHeight: .infinity).background(GioColor.page))
        }
    }

    func testApplyFeedback() throws {
        try SnapshotHarness.render("dd03-feedback", size: CGSize(width: 720, height: 360)) {
            page(
                VStack(spacing: GioSpacing.l) {
                    ApplyToastView(toast: ApplyToast(feedback: .applied(warnings: [])), onDismiss: {})
                    ApplyToastView(
                        toast: ApplyToast(feedback: .rejected(messages: ["line 4: gaps must be a number"])), onDismiss: {}
                    )
                    ApplyBar(state: .visible(canApply: true, problemCount: 0), onApply: {}, onRevert: {})
                    ApplyBar(state: .visible(canApply: false, problemCount: 2), onApply: {}, onRevert: {})
                }
                .padding(GioSpacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GioColor.page)
            )
        }
    }

    func testOverviewContrast() throws {
        try SnapshotHarness.render("dd03-overview", size: CGSize(width: 820, height: 1000)) {
            page(OverviewDashboard(facts: OverviewFixture.facts(accessibility: true, screenRecording: true), config: OverviewFixture.config))
        }
    }

    func testAccentFillsAcrossAccents() throws {
        let accents = ["#7fc8ff", "#ffc87f", "#a6e3a1", "#f38ba8", "#0a3d91", "#8e24aa", "#ffffff"]
        try SnapshotHarness.render("dd03-accent-fills", size: CGSize(width: 560, height: 480)) {
            VStack(alignment: .leading, spacing: GioSpacing.s) {
                ForEach(accents, id: \.self) { hex in
                    HStack(spacing: GioSpacing.m) {
                        SidebarHeader(status: SessionStatus(kind: .ok, label: "Running"), version: hex)
                            .frame(width: 220, alignment: .leading)
                        WorkspacePill(entry: WorkspaceEntry(index: 2, windows: 5, columns: 4, isActive: true))
                            .frame(width: 220)
                    }
                    .environment(\.gioAccent, ThemeColor(hex: hex)!)
                }
            }
            .padding(GioSpacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GioColor.page)
        }
    }
}

enum SettingsFixture {
    static let config: GioConfig = {
        var config = GioConfig()
        config.rules = [
            WindowRule(app: "Safari", mode: .floating, workspace: 3),
            WindowRule(app: "Music", workspace: 4),
            WindowRule(app: "Terminal", mode: .tiled),
            WindowRule(app: "Figma Helper", mode: .floating),
            WindowRule(app: "Notes"),
        ]
        return config
    }()
}
