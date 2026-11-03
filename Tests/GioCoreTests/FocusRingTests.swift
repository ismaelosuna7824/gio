import CoreGraphics
import XCTest
@testable import GioCore

/// NF-01: the focus ring model (pure), its coalescing mailbox and its config.
final class FocusRingTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let window = CGRect(x: 100, y: 100, width: 600, height: 500)

    private func state(
        config: FocusRingSectionConfig = FocusRingSectionConfig(),
        focused: FocusRingWindow? = FocusRingWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 500)),
        displays: [CGRect]? = nil,
        alone: Bool = false
    ) -> FocusRingState {
        focusRingState(config: config, focused: focused, displays: displays ?? [display], alone: alone)
    }

    // MARK: visibility table

    func testShownAroundTheFocusedWindow() {
        guard case .shown(let ring) = state() else {
            return XCTFail("expected a shown ring")
        }
        XCTAssertEqual(ring.width, 2, "2 pt is the default thickness")
        XCTAssertEqual(ring.color, ThemeColor(hex: "#7fc8ff"))
    }

    func testHiddenWhenFeatureDisabled() {
        XCTAssertEqual(state(config: FocusRingSectionConfig(enabled: false)), .hidden)
    }

    func testHiddenWhenWidthIsZero() {
        XCTAssertEqual(state(config: FocusRingSectionConfig(width: 0)), .hidden)
    }

    func testHiddenWithoutFocusedWindow() {
        XCTAssertEqual(state(focused: nil), .hidden)
    }

    func testHiddenWhenFrameUnknown() {
        XCTAssertEqual(state(focused: FocusRingWindow(frame: nil)), .hidden)
    }

    func testHiddenWhenMinimized() {
        XCTAssertEqual(state(focused: FocusRingWindow(frame: window, isMinimized: true)), .hidden)
    }

    /// Live 2026-10-15: a floating window (Finder by rule) kept the ring at
    /// its old place while the user dragged it: Gio does not follow a
    /// floating window's own moves, so the ring would sit apart from it.
    func testHiddenForAFloatingWindow() {
        XCTAssertEqual(state(focused: FocusRingWindow(frame: window, isFloating: true)), .hidden)
    }

    func testFullscreenRingShownWhenTheGapFitsItAndHidingIsOff() {
        let fullscreen = FocusRingWindow(frame: window, isFullscreen: true)
        let config = FocusRingSectionConfig(hideInFullscreen: false)
        for gap in [CGFloat(4), 8] {
            guard case .shown(let ring) = focusRingState(
                config: config, focused: fullscreen, displays: [display], fullscreenGap: gap
            ) else {
                return XCTFail("expected a ring with gap \(gap)")
            }
            XCTAssertEqual(ring.frame, window.insetBy(dx: -2, dy: -2))
        }
        XCTAssertEqual(
            focusRingState(config: config, focused: fullscreen, displays: [display], fullscreenGap: 1),
            .hidden
        )
    }

    func testFullscreenRingHiddenByDefault() {
        XCTAssertTrue(FocusRingSectionConfig().hideInFullscreen)
        // Even with a gap that would fit the ring.
        let fullscreen = FocusRingWindow(frame: window, isFullscreen: true)
        XCTAssertEqual(
            focusRingState(config: FocusRingSectionConfig(), focused: fullscreen, displays: [display], fullscreenGap: 8),
            .hidden
        )
    }

    /// NF-09 follow-up (live 2026-11-03): maximizing with Alt+F keeps the
    /// ring: it is an explicit state the user wants to see, not an accident.
    func testMaximizedColumnKeepsItsRing() {
        let maximized = FocusRingWindow(frame: window, isMaximized: true)
        guard case .shown(let ring) = state(focused: maximized) else {
            return XCTFail("a maximized column keeps the ring")
        }
        XCTAssertEqual(ring.frame, window.insetBy(dx: -2, dy: -2))
        // And it is not treated as "alone" even when nothing else is visible.
        guard case .shown = state(focused: maximized, alone: true) else {
            return XCTFail("maximize is explicit: hide-when-alone does not apply")
        }
    }

    func testTiledWindowKeepsItsRingWhenHidingIsOn() {
        guard case .shown = state(focused: FocusRingWindow(frame: window, isMaximized: false)) else {
            return XCTFail("expected a ring")
        }
    }

    func testHideInFullscreenParsesAndRoundTrips() throws {
        let (off, _) = try parseGioConfig("[focus-ring]\nhide-in-fullscreen = false\n").get()
        XCTAssertFalse(off.focusRing.hideInFullscreen)
        let (on, _) = try parseGioConfig("[focus-ring]\nhide-in-fullscreen = true\n").get()
        XCTAssertTrue(on.focusRing.hideInFullscreen)
        // NF-09: the old name still parses (a config written before the rename).
        let (legacy, legacyWarnings) = try parseGioConfig("[focus-ring]\nhide-when-maximized = false\n").get()
        XCTAssertFalse(legacy.focusRing.hideInFullscreen)
        XCTAssertEqual(legacyWarnings, [])
        XCTAssertTrue(defaultConfigTemplate().contains("hide-in-fullscreen = true"))
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        XCTAssertTrue(form.hideInFullscreen)
        form.hideInFullscreen = false
        let result = try patchGioConfig(defaultConfigTemplate(), edits: form.edits).get()
        XCTAssertFalse(result.config.focusRing.hideInFullscreen)
    }

    // MARK: hide-when-alone

    /// NF-02 (live 2026-11-03): a lone column expanded to the full width is
    /// not "maximized", so the ring framed the whole screen. When the focused
    /// window is the only visible one there is nothing to tell apart.
    func testHiddenWhenTheFocusedWindowIsTheOnlyVisibleOneByDefault() {
        XCTAssertTrue(FocusRingSectionConfig().hideWhenAlone)
        XCTAssertEqual(state(alone: true), .hidden)
    }

    func testShownWhenAloneAndHidingIsOff() {
        guard case .shown = state(config: FocusRingSectionConfig(hideWhenAlone: false), alone: true) else {
            return XCTFail("expected a ring with hide-when-alone off")
        }
    }

    func testAnotherVisibleWindowOnTheSameDisplayIsNotAlone() {
        let other = CGRect(x: 800, y: 100, width: 600, height: 500)
        XCTAssertFalse(focusRingIsAlone(focused: window, others: [other], displays: [display]))
        XCTAssertTrue(focusRingIsAlone(focused: window, others: [], displays: [display]))
    }

    func testAWindowOnAnotherDisplayDoesNotCount() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let other = CGRect(x: 1600, y: 100, width: 800, height: 600)
        XCTAssertTrue(
            focusRingIsAlone(focused: window, others: [other], displays: [display, second]),
            "a neighbour on the second display is not next to the focused window"
        )
    }

    func testAParkedNeighbourIsNotVisible() {
        // Parking keeps a 1 pt sliver on screen.
        let parked = CGRect(x: 1439, y: 100, width: 600, height: 500)
        XCTAssertTrue(focusRingIsAlone(focused: window, others: [parked], displays: [display]))
    }

    func testHideWhenAloneParsesAndRoundTrips() throws {
        let (off, _) = try parseGioConfig("[focus-ring]\nhide-when-alone = false\n").get()
        XCTAssertFalse(off.focusRing.hideWhenAlone)
        XCTAssertTrue(defaultConfigTemplate().contains("hide-when-alone = true"))
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        XCTAssertTrue(form.hideWhenAlone)
        form.hideWhenAlone = false
        let result = try patchGioConfig(defaultConfigTemplate(), edits: form.edits).get()
        XCTAssertFalse(result.config.focusRing.hideWhenAlone)
    }

    func testHiddenWhenFullscreen() {
        XCTAssertEqual(state(focused: FocusRingWindow(frame: window, isFullscreen: true)), .hidden)
    }

    func testHiddenWhenParkedOffscreenSliver() {
        // A parked window keeps a 1 pt sliver inside the display.
        let parked = CGRect(x: 1439, y: 100, width: 600, height: 500)
        XCTAssertEqual(state(focused: FocusRingWindow(frame: parked)), .hidden)
    }

    func testHiddenWhenHungBelowTheDisplay() {
        let hidden = CGRect(x: 100, y: -600, width: 600, height: 500)
        XCTAssertEqual(state(focused: FocusRingWindow(frame: hidden)), .hidden)
    }

    func testShownWhilePartiallyScrolledIn() {
        let partial = CGRect(x: 1240, y: 100, width: 600, height: 500)
        guard case .shown = state(focused: FocusRingWindow(frame: partial)) else {
            return XCTFail("a window 200 pt inside the display keeps its ring")
        }
    }

    func testShownOnASecondDisplay() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let onSecond = CGRect(x: 1600, y: 100, width: 800, height: 600)
        guard case .shown = state(focused: FocusRingWindow(frame: onSecond), displays: [display, second]) else {
            return XCTFail("expected a ring on the second display")
        }
    }

    func testFloatingWindowGetsTheRingLikeAnyOther() {
        // Mode never enters the model: a floating window is just a frame.
        guard case .shown = state() else {
            return XCTFail("expected a shown ring")
        }
    }

    func testMaskedHiddenWhileGioIsFrontmost() {
        let shown = state()
        XCTAssertEqual(shown.masked(gioIsFrontmost: true), .hidden)
        XCTAssertEqual(shown.masked(gioIsFrontmost: false), shown)
        XCTAssertEqual(FocusRingState.hidden.masked(gioIsFrontmost: false), .hidden)
    }

    // MARK: geometry

    func testOverlayFrameIsTheWindowOutsetByTheWidth() {
        guard case .shown(let ring) = state(config: FocusRingSectionConfig(width: 6)) else {
            return XCTFail("expected a shown ring")
        }
        XCTAssertEqual(ring.frame, CGRect(x: 94, y: 94, width: 612, height: 512))
    }

    func testStrokeRectSitsHalfAWidthInsideTheOverlay() {
        let ring = FocusRingGeometry(
            frame: CGRect(x: 94, y: 94, width: 612, height: 512), width: 6, color: ThemeColor(hex: "#fff")!
        )
        XCTAssertEqual(ring.strokeRect, CGRect(x: 3, y: 3, width: 606, height: 506))
        XCTAssertEqual(ring.strokeCornerRadius, focusRingWindowCornerRadius + 3)
    }

    func testExplicitColorWinsThenThemeThenNiriDefault() {
        let explicit = ThemeColor(hex: "#112233")!
        var theme = GioTheme(name: "t")
        theme.borderActive = ThemeColor(hex: "#445566")
        XCTAssertEqual(FocusRingSectionConfig(activeColor: explicit).resolvedColor(theme: theme), explicit)
        XCTAssertEqual(FocusRingSectionConfig().resolvedColor(theme: theme), theme.borderActive)
        XCTAssertEqual(FocusRingSectionConfig().resolvedColor(theme: GioTheme(name: "bare")), FocusRingSectionConfig.defaultColor)
        XCTAssertEqual(FocusRingSectionConfig().resolvedColor(theme: nil), FocusRingSectionConfig.defaultColor)
    }

    // MARK: coalescing

    func testMailboxSchedulesOneDrainForAFlood() {
        let mailbox = LatestValueMailbox<Int>()
        XCTAssertTrue(mailbox.post(1))
        for value in 2...500 {
            XCTAssertFalse(mailbox.post(value), "only the first post asks for a main-thread hop")
        }
        XCTAssertEqual(mailbox.take(), 500)
        XCTAssertNil(mailbox.take())
    }

    func testMailboxSchedulesAgainAfterADrain() {
        let mailbox = LatestValueMailbox<Int>()
        XCTAssertTrue(mailbox.post(1))
        XCTAssertEqual(mailbox.take(), 1)
        XCTAssertTrue(mailbox.post(2))
        XCTAssertEqual(mailbox.take(), 2)
    }

    func testMailboxDropsRepeatsOfTheLastPostedValue() {
        let mailbox = LatestValueMailbox<Int>()
        XCTAssertTrue(mailbox.post(1))
        XCTAssertEqual(mailbox.take(), 1)
        XCTAssertFalse(mailbox.post(1), "an unchanged state never reaches main")
        XCTAssertNil(mailbox.take())
    }

    func testMailboxPendingValueSurvivesARepostOfTheOlderOne() {
        let mailbox = LatestValueMailbox<Int>()
        XCTAssertTrue(mailbox.post(1))
        XCTAssertFalse(mailbox.post(2))
        XCTAssertFalse(mailbox.post(1))
        XCTAssertEqual(mailbox.take(), 1)
    }

    // MARK: config

    func testDefaults() {
        let ring = defaultGioConfig().focusRing
        XCTAssertTrue(ring.enabled)
        XCTAssertEqual(ring.width, 2)
        XCTAssertNil(ring.activeColor)
        XCTAssertTrue(ring.hideWhenAlone)
        XCTAssertEqual(FocusRingSectionConfig.defaultColor.hex, "#7FC8FF")
    }

    func testParsesAllKeys() throws {
        let text = "[focus-ring]\nenabled = false\nwidth = 7\nactive-color = \"#AABBCC\"\n"
        let (config, warnings) = try parseGioConfig(text).get()
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(config.focusRing.enabled)
        XCTAssertEqual(config.focusRing.width, 7)
        XCTAssertEqual(config.focusRing.activeColor, ThemeColor(hex: "#AABBCC"))
    }

    func testWidthIsClampedWithAWarning() throws {
        let (high, highWarnings) = try parseGioConfig("[focus-ring]\nwidth = 99\n").get()
        XCTAssertEqual(high.focusRing.width, 20)
        XCTAssertEqual(highWarnings.count, 1)
        XCTAssertTrue(highWarnings[0].contains("focus-ring.width"))
        let (low, _) = try parseGioConfig("[focus-ring]\nwidth = -3\n").get()
        XCTAssertEqual(low.focusRing.width, 0)
    }

    func testInvalidValuesAreErrorsNamingTheLine() {
        for (text, fragment) in [
            ("[focus-ring]\nenabled = 1\n", "focus-ring.enabled expects true or false"),
            ("[focus-ring]\nwidth = \"wide\"\n", "focus-ring.width expects a number"),
            ("[focus-ring]\nactive-color = \"blue\"\n", "focus-ring.active-color expects a hex color"),
            ("[focus-ring]\nactive-color = 5\n", "focus-ring.active-color expects a hex color"),
        ] {
            switch parseGioConfig(text) {
            case .success:
                XCTFail("expected an error for \(text)")
            case .failure(let errors):
                XCTAssertEqual(errors.messages.count, 1)
                XCTAssertTrue(errors.messages[0].hasPrefix("line 2:"), errors.messages[0])
                XCTAssertTrue(errors.messages[0].contains(fragment), errors.messages[0])
            }
        }
    }

    func testUnknownKeyWarns() throws {
        let (_, warnings) = try parseGioConfig("[focus-ring]\nglow = true\n").get()
        XCTAssertEqual(warnings, ["line 2: unknown focus-ring key 'glow', ignored"])
    }

    func testTemplateDocumentsTheSectionAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("[focus-ring]"))
        let (config, warnings) = try parseGioConfig(template).get()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.focusRing, FocusRingSectionConfig())
    }

    // MARK: settings form and patcher

    func testFormValidatesWidthAndColor() {
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        XCTAssertEqual(form.problems, [])
        form.width = 21
        XCTAssertEqual(form.problems.count, 1)
        form.width = 4
        form.colorText = "nope"
        XCTAssertEqual(form.problems.count, 1)
        form.colorText = "#0af"
        XCTAssertEqual(form.problems, [])
    }

    func testFormEditsRoundTripThroughThePatcher() throws {
        var form = FocusRingSettingsForm(config: FocusRingSectionConfig())
        form.enabled = false
        form.width = 6
        form.colorText = "#abcdef"
        let result = try patchGioConfig(defaultConfigTemplate(), edits: form.edits).get()
        XCTAssertFalse(result.config.focusRing.enabled)
        XCTAssertEqual(result.config.focusRing.width, 6)
        XCTAssertEqual(result.config.focusRing.activeColor, ThemeColor(hex: "#abcdef"))
    }

    func testPatcherCreatesTheTableInAConfigWithoutOne() throws {
        let result = try patchGioConfig("[layout]\ngaps = 8\n", edits: focusRingEdits(enabled: true, width: 5, colorHex: "#7fc8ff")).get()
        XCTAssertTrue(result.text.contains("[focus-ring]"))
        XCTAssertEqual(result.config.focusRing.width, 5)
    }

    func testFormShowsTheResolvedColor() {
        XCTAssertEqual(FocusRingSettingsForm(config: FocusRingSectionConfig()).colorText, "#7FC8FF")
    }
}
