import XCTest
@testable import GioCore

/// TG-02: the `[gestures]` table. Every key is validated; a bad value only
/// warns and keeps its default (a gesture typo never rejects the rest of the
/// config); finger-count conflicts are rejected; Settings edits keep the
/// file's comments.
final class GesturesConfigTests: XCTestCase {
    private func parse(_ text: String) throws -> (GioConfig, [String]) {
        try parseGioConfig(text).get()
    }

    func testDefaults() {
        let gestures = GioConfig().gestures
        XCTAssertTrue(gestures.scroll)
        XCTAssertEqual(gestures.scrollFingers, 3)
        XCTAssertEqual(gestures.scrollSensitivity, 1.0)
        XCTAssertTrue(gestures.natural)
        XCTAssertTrue(gestures.workspaceSwipe)
        XCTAssertEqual(gestures.workspaceFingers, 3)
        XCTAssertFalse(gestures.overview, "macOS uses four-finger swipe up for Mission Control by default")
        XCTAssertEqual(gestures.overviewFingers, 4)
        XCTAssertTrue(gestures.anyEnabled)
    }

    func testEveryKeyParses() throws {
        let (config, warnings) = try parse("""
        [gestures]
        scroll = false
        scroll-fingers = 4
        scroll-sensitivity = 1.5
        natural = false
        workspace-swipe = false
        workspace-fingers = 4
        overview = true
        overview-fingers = 5
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.gestures, GesturesSectionConfig(
            scroll: false, scrollFingers: 4, scrollSensitivity: 1.5, natural: false,
            workspaceSwipe: false, workspaceFingers: 4, overview: true, overviewFingers: 5
        ))
    }

    func testInvalidValuesWarnAndKeepTheDefaultsWithoutRejectingTheFile() throws {
        let (config, warnings) = try parse("""
        [layout]
        gaps = 12
        [gestures]
        scroll = "yes"
        scroll-fingers = 2
        workspace-fingers = 6
        overview-fingers = 3.5
        scroll-sensitivity = "fast"
        natural = 1
        swipe-to-close = true
        """)
        XCTAssertEqual(config.layout.gaps, 12, "the rest of the file still applies")
        XCTAssertEqual(config.gestures, GesturesSectionConfig())
        XCTAssertEqual(warnings, [
            "line 4: gestures.scroll expects true or false, using true",
            "line 5: gestures.scroll-fingers expects 3, 4 or 5 fingers, using 3",
            "line 6: gestures.workspace-fingers expects 3, 4 or 5 fingers, using 3",
            "line 7: gestures.overview-fingers expects 3, 4 or 5 fingers, using 4",
            "line 8: gestures.scroll-sensitivity expects a number from 0.1 to 5.0, using 1.0",
            "line 9: gestures.natural expects true or false, using true",
            "line 10: unknown gestures key 'swipe-to-close', ignored",
        ])
    }

    func testSensitivityIsClampedIntoItsRange() throws {
        let (config, warnings) = try parse("[gestures]\nscroll-sensitivity = 9\n")
        XCTAssertEqual(config.gestures.scrollSensitivity, 5.0)
        XCTAssertEqual(warnings, ["line 2: gestures.scroll-sensitivity clamped to 5.0 (valid 0.1-5.0)"])
    }

    func testWorkspaceSwipeAndOverviewCannotShareTheirFingers() throws {
        let (config, warnings) = try parse("""
        [gestures]
        workspace-fingers = 4
        overview = true
        """)
        XCTAssertEqual(config.gestures.workspaceFingers, 4)
        XCTAssertFalse(config.gestures.overview, "the vertical swipe keeps its fingers, the overview turns off")
        XCTAssertEqual(warnings, [
            "gestures.overview-fingers = 4 is also gestures.workspace-fingers; both swipe vertically, overview turned off",
        ])
    }

    func testSharedFingersOnDifferentAxesOrWithAGestureOffAreFine() throws {
        let (both, bothWarnings) = try parse("[gestures]\nscroll-fingers = 4\noverview = true\n")
        XCTAssertTrue(both.gestures.overview)
        XCTAssertEqual(bothWarnings, [])
        let (off, offWarnings) = try parse("[gestures]\nworkspace-swipe = false\nworkspace-fingers = 4\noverview = true\n")
        XCTAssertTrue(off.gestures.overview)
        XCTAssertEqual(offWarnings, [])
    }

    func testRecognizerSettingsFollowTheConfig() {
        var gestures = GesturesSectionConfig()
        XCTAssertEqual(gestures.recognizerSettings, GestureRecognizerSettings(horizontalFingers: 3, verticalFingers: [3]))
        gestures.overview = true
        XCTAssertEqual(gestures.recognizerSettings.verticalFingers, [3, 4])
        gestures.scroll = false
        gestures.workspaceSwipe = false
        XCTAssertNil(gestures.recognizerSettings.horizontalFingers)
        XCTAssertEqual(gestures.recognizerSettings.verticalFingers, [4])
        gestures.overview = false
        XCTAssertFalse(gestures.anyEnabled)
        XCTAssertEqual(gestures.recognizerSettings.minimumFingers, 0)
    }

    func testTemplateDocumentsTheTableAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("[gestures]"))
        let (config, warnings) = try parse(template)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.gestures, GesturesSectionConfig())
    }

    func testSettingsFormEditsKeepCommentsAndRoundTrip() throws {
        let original = """
        # mine
        [gestures]
        # keep this
        scroll = true # inline
        """
        var form = GesturesSettingsForm(config: GesturesSectionConfig())
        form.scroll = false
        form.scrollFingers = 4
        form.scrollSensitivity = 1.25
        form.natural = false
        form.overview = true
        form.overviewFingers = 5
        XCTAssertEqual(form.problems, [])
        let patched = try patchGioConfig(original, edits: form.edits).get()
        XCTAssertTrue(patched.text.contains("# mine"))
        XCTAssertTrue(patched.text.contains("# keep this"))
        XCTAssertTrue(patched.text.contains("scroll = false  # inline"))
        XCTAssertEqual(patched.config.gestures, GesturesSectionConfig(
            scroll: false, scrollFingers: 4, scrollSensitivity: 1.25, natural: false,
            workspaceSwipe: true, workspaceFingers: 3, overview: true, overviewFingers: 5
        ))
        XCTAssertEqual(GesturesSettingsForm(config: patched.config.gestures), form)
    }

    func testSettingsFormRejectsConflictsAndBadSensitivity() {
        var form = GesturesSettingsForm(config: GesturesSectionConfig())
        form.overview = true
        form.overviewFingers = 3
        form.scrollSensitivity = 0
        XCTAssertEqual(form.problems, [
            "Sensitivity must be 0.1 to 5.0.",
            "Workspace swipe and overview both use 3 fingers; pick different counts.",
        ])
        form.workspaceSwipe = false
        form.scrollSensitivity = 2
        XCTAssertEqual(form.problems, [])
    }
}
