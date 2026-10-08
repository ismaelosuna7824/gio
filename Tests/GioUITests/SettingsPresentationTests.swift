import CoreGraphics
import GioCore
import XCTest
@testable import GioUI

/// DD-03: the pure pieces behind the redesigned settings sections — layout
/// preview geometry, motion curve sampling, draft / apply-bar state, rule
/// rows and the focus preview.
final class SettingsPresentationTests: XCTestCase {
    private let display = CGSize(width: 1000, height: 600)

    private func layoutForm(
        gaps: Double = 8, padding: Double = 8, fraction: Double? = 0.5, points: Double? = nil,
        presets: String = "0.5", fullscreenGap: Double? = nil
    ) -> LayoutSettingsForm {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        form.gaps = gaps
        form.padding = padding
        if let points {
            form.widthKind = .points
            form.widthValue = points
        } else {
            form.widthKind = .fraction
            form.widthValue = fraction ?? 0.5
        }
        form.presetsText = presets
        if let fullscreenGap {
            form.fullscreenGapFollowsGaps = false
            form.fullscreenGap = fullscreenGap
        } else {
            form.fullscreenGapFollowsGaps = true
        }
        return form
    }

    // MARK: - Layout preview

    func testColumnsModeCentersTheFocusedColumnWithGapsAndPadding() {
        let preview = layoutPreviewGeometry(layoutForm(), display: display, mode: .columns)
        // 0.5 * (1000 - 2 * 8 + 8) - 8 = 488
        XCTAssertEqual(preview.columns.count, 3)
        XCTAssertEqual(preview.focusedIndex, 1)
        XCTAssertEqual(preview.columns[1], CGRect(x: 256, y: 8, width: 488, height: 584))
        XCTAssertEqual(preview.columns[0], CGRect(x: -240, y: 8, width: 488, height: 584))
        XCTAssertEqual(preview.columns[2], CGRect(x: 752, y: 8, width: 488, height: 584))
    }

    func testAThirdFractionFitsThreeColumnsEdgeToEdge() {
        let preview = layoutPreviewGeometry(
            layoutForm(gaps: 10, padding: 20, fraction: 1.0 / 3), display: display, mode: .columns
        )
        XCTAssertEqual(preview.columns[0].minX, 20, accuracy: 0.001)
        XCTAssertEqual(preview.columns[2].maxX, 980, accuracy: 0.001)
        XCTAssertEqual(preview.columns[1].minX - preview.columns[0].maxX, 10, accuracy: 0.001)
    }

    func testPointWidthIsUsedAsIsAndCappedToTheViewport() {
        let fixed = layoutPreviewGeometry(layoutForm(points: 600), display: display, mode: .columns)
        XCTAssertEqual(fixed.columns[1].width, 600)
        let huge = layoutPreviewGeometry(layoutForm(points: 5000), display: display, mode: .columns)
        XCTAssertEqual(huge.columns[1].width, 984)
    }

    func testMaximizedFillsTheViewportInsidePadding() {
        let preview = layoutPreviewGeometry(layoutForm(padding: 12), display: display, mode: .maximized)
        XCTAssertEqual(preview.columns[preview.focusedIndex], CGRect(x: 12, y: 12, width: 976, height: 576))
    }

    func testFullscreenUsesTheFullscreenGapOrFollowsGaps() {
        let own = layoutPreviewGeometry(layoutForm(fullscreenGap: 20), display: display, mode: .fullscreen)
        XCTAssertEqual(own.columns[own.focusedIndex], CGRect(x: 20, y: 20, width: 960, height: 560))
        let follows = layoutPreviewGeometry(layoutForm(gaps: 6), display: display, mode: .fullscreen)
        XCTAssertEqual(follows.columns[follows.focusedIndex], CGRect(x: 6, y: 6, width: 988, height: 588))
    }

    func testPresetWidthsResolveFractionsAndPoints() {
        let preview = layoutPreviewGeometry(layoutForm(presets: "0.5, 800"), display: display, mode: .columns)
        XCTAssertEqual(preview.presetWidths, [488, 800])
        XCTAssertEqual(preview.presetLabels, ["50%", "800 pt"])
        XCTAssertEqual(preview.padding, 8)
        let invalid = layoutPreviewGeometry(layoutForm(presets: "abc"), display: display, mode: .columns)
        XCTAssertEqual(invalid.presetWidths, [])
        XCTAssertEqual(invalid.presetLabels, [])
        let thirds = layoutPreviewGeometry(layoutForm(presets: "0.33333, 0.66667, 1"), display: display, mode: .columns)
        XCTAssertEqual(thirds.presetLabels, ["33%", "67%", "100%"])
    }

    func testInvalidNumbersAreSanitizedInsteadOfBreakingThePreview() {
        let preview = layoutPreviewGeometry(
            layoutForm(gaps: -5, padding: .nan, fraction: 7), display: display, mode: .columns
        )
        XCTAssertEqual(preview.columns[1].minY, 0)
        XCTAssertTrue(preview.columns.allSatisfy { $0.width.isFinite && $0.width > 0 })
        XCTAssertLessThanOrEqual(preview.columns[1].width, display.width)
    }

    func testLayoutResetKeepsTheFocusSectionsCenterMode() {
        var form = layoutForm(gaps: 30)
        form.centerFocusedColumn = .always
        let reset = layoutDefaults(preserving: form)
        XCTAssertEqual(reset.gaps, 8)
        XCTAssertEqual(reset.centerFocusedColumn, .always)
    }

    // MARK: - Motion curve

    private func spring(_ zeta: Double, _ k: Double) -> MotionPreviewParameters {
        MotionPreviewParameters(
            enabled: true, curve: .spring, dampingRatio: zeta, stiffness: k, durationMilliseconds: 200
        )
    }

    func testSpringProgressMatchesTheSpringSolution() {
        let params = spring(0.6, 800)
        let solver = SpringParameters(dampingRatio: 0.6, stiffness: 800, epsilon: SpringParameters.niri.epsilon)
        for t in stride(from: 0.0, through: 0.5, by: 0.05) {
            let expected = 1 + solver.state(displacement: -1, velocity: 0, at: t).displacement
            XCTAssertEqual(motionProgress(params, at: t), expected, accuracy: 1e-9, "t=\(t)")
        }
        XCTAssertEqual(motionProgress(params, at: 0), 0, accuracy: 1e-9)
    }

    func testSpringDurationIsTheSettleTimeAndEndsAtRest() {
        let params = spring(1, 800)
        let duration = motionDuration(params)
        XCTAssertGreaterThan(duration, 0.05)
        XCTAssertLessThanOrEqual(duration, SpringParameters.maxDuration)
        XCTAssertEqual(motionProgress(params, at: duration), 1, accuracy: 0.01)
    }

    func testCriticalSpringNeverOvershootsButABouncyOneDoes() {
        let critical = motionCurve(spring(1, 800), sampleCount: 120)
        XCTAssertLessThanOrEqual(critical.maxProgress, 1 + 1e-9)
        let bouncy = motionCurve(spring(0.3, 800), sampleCount: 120)
        XCTAssertGreaterThan(bouncy.maxProgress, 1.05)
    }

    func testEaseOutUsesTheDurationAndCubicEasing() {
        let params = MotionPreviewParameters(
            enabled: true, curve: .easeOut, dampingRatio: 1, stiffness: 800, durationMilliseconds: 200
        )
        XCTAssertEqual(motionDuration(params), 0.2, accuracy: 1e-9)
        XCTAssertEqual(motionProgress(params, at: 0.1), eased(0.5, easing: .easeOut), accuracy: 1e-9)
        XCTAssertEqual(motionProgress(params, at: 0.3), 1, accuracy: 1e-9)
    }

    func testDisabledOrZeroDurationIsInstant() {
        var params = spring(1, 800)
        params.enabled = false
        XCTAssertEqual(motionDuration(params), 0)
        XCTAssertEqual(motionProgress(params, at: 0), 1)
        let zero = MotionPreviewParameters(
            enabled: true, curve: .easeOut, dampingRatio: 1, stiffness: 800, durationMilliseconds: 0
        )
        XCTAssertEqual(motionDuration(zero), 0)
        XCTAssertEqual(motionProgress(zero, at: 0), 1)
    }

    func testCurveSamplesSpanTheDurationEvenly() {
        let params = spring(0.8, 600)
        let curve = motionCurve(params, sampleCount: 11)
        XCTAssertEqual(curve.samples.count, 11)
        XCTAssertEqual(curve.samples.first?.time, 0)
        XCTAssertEqual(curve.samples.last?.time ?? 0, curve.duration, accuracy: 1e-9)
        for sample in curve.samples {
            XCTAssertEqual(sample.progress, motionProgress(params, at: sample.time), accuracy: 1e-12)
        }
    }

    func testAnimationsFormRoundTripsConfigAndBuildsEdits() {
        let config = AnimationsSectionConfig(curve: .easeOut, springDampingRatio: 0.7, springStiffness: 900)
        var form = AnimationsForm(config: config)
        XCTAssertEqual(form.curve, .easeOut)
        XCTAssertEqual(form.preview.dampingRatio, 0.7)
        form.durationMilliseconds = 250
        let expected = animationEdits(
            enabled: true, durationMilliseconds: 250, curve: .easeOut, springDampingRatio: 0.7,
            springStiffness: 900, resize: .never, renderer: .snapshot, focusedGrow: .start, nativeZoom: true
        )
        XCTAssertEqual(Array(form.edits.prefix(expected.count)), expected)
    }

    // MARK: - Per-animation (NA-04)

    func testPerAnimationFormInheritsByDefault() {
        let form = AnimationsForm(config: AnimationsSectionConfig())
        XCTAssertEqual(form.kinds.count, AnimationKind.allCases.count)
        for kind in AnimationKind.allCases {
            let row = form.kinds[kind]!
            XCTAssertTrue(row.enabled)
            XCTAssertFalse(row.custom, "\(kind) inherits global")
        }
        XCTAssertEqual(form.openOffset, 24)
        XCTAssertFalse(form.closeGhost)
    }

    func testPerAnimationFormRoundTripsThroughTheConfigFile() throws {
        var config = AnimationsSectionConfig()
        config.overrides[.windowMovement] = AnimationOverride(curve: .easeOut, durationMilliseconds: 120)
        config.overrides[.workspaceSwitch] = AnimationOverride(curve: .spring, springDampingRatio: 0.6, springStiffness: 500)
        config.overrides[.windowClose] = AnimationOverride(enabled: false)
        config.openOffset = 40
        config.closeGhost = true
        let form = AnimationsForm(config: config)
        XCTAssertTrue(form.kinds[.windowMovement]!.custom)
        XCTAssertEqual(form.kinds[.windowMovement]!.durationMilliseconds, 120)
        XCTAssertFalse(form.kinds[.windowClose]!.enabled)

        let patched = try patchGioConfig("[animations]\nenabled = true\n", edits: form.edits).get()

        XCTAssertEqual(patched.config.animations, config)
        XCTAssertEqual(patched.warnings, [])
    }

    func testTurningCustomOnStartsFromTheGlobalValuesAndOffRemovesTheKeys() throws {
        var form = AnimationsForm(config: AnimationsSectionConfig())
        form.curve = .easeOut
        form.durationMilliseconds = 300
        form.setCustom(.windowResize, true)
        XCTAssertEqual(form.kinds[.windowResize]!.curve, .easeOut)
        XCTAssertEqual(form.kinds[.windowResize]!.durationMilliseconds, 300)
        XCTAssertEqual(form.preview(for: .windowResize).durationMilliseconds, 300)

        form.kinds[.windowResize]!.durationMilliseconds = 90
        let custom = try patchGioConfig("", edits: form.edits).get()
        XCTAssertEqual(custom.config.animations.overrides[.windowResize], AnimationOverride(curve: .easeOut, durationMilliseconds: 90))

        form.setCustom(.windowResize, false)
        let inherited = try patchGioConfig(custom.text, edits: form.edits).get()
        XCTAssertNil(inherited.config.animations.overrides[.windowResize])
        XCTAssertFalse(inherited.text.contains("[animations.window-resize]"))
    }

    // MARK: - Draft and apply bar

    func testDraftIsDirtyOnlyWhenCurrentDiffersFromSaved() {
        var draft = SettingsDraft(saved: 1)
        XCTAssertFalse(draft.isDirty)
        draft.current = 2
        XCTAssertTrue(draft.isDirty)
        draft.current = 1
        XCTAssertFalse(draft.isDirty)
    }

    func testRevertRestoresTheSavedValue() {
        var draft = SettingsDraft(saved: 1)
        draft.current = 5
        draft.revert()
        XCTAssertEqual(draft.current, 1)
        XCTAssertFalse(draft.isDirty)
    }

    func testAdoptFollowsTheConfigOnlyWhileClean() {
        var clean = SettingsDraft(saved: 1)
        clean.adopt(saved: 3)
        XCTAssertEqual(clean.current, 3)
        XCTAssertFalse(clean.isDirty)

        var edited = SettingsDraft(saved: 1)
        edited.current = 7
        edited.adopt(saved: 3)
        XCTAssertEqual(edited.current, 7, "unsaved edits survive a config refresh")
        XCTAssertEqual(edited.saved, 3)
    }

    func testCommitMakesTheCurrentValueTheSavedOne() {
        var draft = SettingsDraft(saved: 1)
        draft.current = 4
        draft.commit()
        XCTAssertEqual(draft.saved, 4)
        XCTAssertFalse(draft.isDirty)
    }

    func testResetToDefaultsIsAnUnsavedEdit() {
        var draft = SettingsDraft(saved: 9)
        draft.reset(to: 1)
        XCTAssertEqual(draft.current, 1)
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(draft.isAtDefaults(1))
    }

    func testApplyBarShowsOnlyWithUnsavedEditsAndBlocksInvalidOnes() {
        XCTAssertEqual(applyBarState(isDirty: false, problems: []), .hidden)
        XCTAssertEqual(applyBarState(isDirty: false, problems: ["x"]), .hidden)
        XCTAssertEqual(applyBarState(isDirty: true, problems: []), .visible(canApply: true, problemCount: 0))
        XCTAssertEqual(applyBarState(isDirty: true, problems: ["a", "b"]), .visible(canApply: false, problemCount: 2))
    }

    func testToastFromFeedback() {
        XCTAssertEqual(ApplyToast(feedback: .applied(warnings: [])), ApplyToast(kind: .success, title: "Applied", details: []))
        XCTAssertEqual(
            ApplyToast(feedback: .applied(warnings: ["w"])),
            ApplyToast(kind: .warning, title: "Applied with warnings", details: ["w"])
        )
        XCTAssertEqual(
            ApplyToast(feedback: .rejected(messages: ["bad"])),
            ApplyToast(kind: .failure, title: "Not applied — config.toml unchanged", details: ["bad"])
        )
    }

    // MARK: - Focus section

    func testFocusDraftCollectsEveryFocusEdit() {
        var config = GioConfig()
        config.layout.centerFocusedColumn = .onOverflow
        config.behavior.focusFollowsMouse = true
        let draft = FocusSectionDraft(config: config)
        XCTAssertEqual(draft.centerFocusedColumn, .onOverflow)
        XCTAssertTrue(draft.focusFollowsMouse)
        XCTAssertEqual(
            draft.edits,
            [.set(table: "layout", key: "center-focused-column", value: .string("on-overflow"))]
                + behaviorEdits(focusFollowsMouse: true, mouseFollowsFocus: true)
                + draft.ring.edits + draft.indicator.edits
        )
        XCTAssertTrue(draft.problems.isEmpty)
    }

    func testFocusDraftProblemsOnlyCountTheActiveIndicator() {
        var draft = FocusSectionDraft(config: GioConfig())
        draft.ring.colorText = "nope"
        draft.indicator.indicator = .dim
        XCTAssertTrue(draft.problems.isEmpty, "ring settings are hidden, so they cannot block Apply")
        draft.indicator.indicator = .ring
        XCTAssertEqual(draft.problems.count, 1)
    }

    func testFocusPreviewStylePerIndicator() {
        var draft = FocusSectionDraft(config: GioConfig())
        draft.indicator.indicator = .dim
        draft.indicator.dimStrength = 0.3
        XCTAssertEqual(focusPreviewStyle(draft), FocusPreviewStyle(unfocusedDim: 0.3, ringWidth: 0, ringColor: nil))
        draft.indicator.indicator = .ring
        draft.ring.width = 4
        draft.ring.colorText = "#ff0000"
        XCTAssertEqual(
            focusPreviewStyle(draft),
            FocusPreviewStyle(unfocusedDim: 0, ringWidth: 4, ringColor: ThemeColor(red: 1, green: 0, blue: 0))
        )
        draft.ring.enabled = false
        XCTAssertEqual(focusPreviewStyle(draft).ringWidth, 0)
        draft.indicator.indicator = .none
        XCTAssertEqual(focusPreviewStyle(draft), FocusPreviewStyle(unfocusedDim: 0, ringWidth: 0, ringColor: nil))
    }

    // MARK: - Rules

    func testRuleRowBadges() {
        let row = RuleRowPresentation(rule: WindowRule(app: "Safari", mode: .floating, workspace: 3))
        XCTAssertEqual(row.title, "Safari")
        XCTAssertEqual(row.initials, "S")
        XCTAssertEqual(row.modeBadge, RuleBadge(label: "Floating", symbol: "macwindow.on.rectangle", kind: .info))
        XCTAssertEqual(row.workspaceBadge, RuleBadge(label: "Workspace 3", symbol: "square.stack.3d.up", kind: .neutral))
        XCTAssertEqual(row.accessibilityLabel, "Safari: floating, workspace 3")
    }

    func testRuleRowWithoutActionsSaysSo() {
        let tiled = RuleRowPresentation(rule: WindowRule(app: "Visual Studio Code", mode: .tiled))
        XCTAssertEqual(tiled.initials, "VS")
        XCTAssertEqual(tiled.modeBadge?.label, "Tiled")
        XCTAssertNil(tiled.workspaceBadge)
        let empty = RuleRowPresentation(rule: WindowRule(app: "Notes"))
        XCTAssertNil(empty.modeBadge)
        XCTAssertNil(empty.workspaceBadge)
        XCTAssertEqual(empty.accessibilityLabel, "Notes: no action")
    }

    func testAppBundleCandidatesLookInTheStandardFolders() {
        let candidates = appBundleCandidates(named: "Safari", home: "/Users/me")
        XCTAssertEqual(candidates, [
            "/Applications/Safari.app",
            "/System/Applications/Safari.app",
            "/System/Applications/Utilities/Safari.app",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            "/Applications/Utilities/Safari.app",
            "/Users/me/Applications/Safari.app",
        ])
        XCTAssertEqual(appBundleCandidates(named: "  ", home: "/Users/me"), [])
        XCTAssertEqual(appBundleCandidates(named: "../x", home: "/Users/me"), [], "no path traversal")
    }
}
