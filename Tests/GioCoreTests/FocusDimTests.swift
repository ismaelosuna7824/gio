import CoreGraphics
import XCTest
@testable import GioCore

/// NF-06: dim inactive windows. The region model (pure), its timing decision,
/// the drawing helpers and the `[focus]` config.
final class FocusDimTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let left = CGRect(x: 10, y: 10, width: 700, height: 850)
    private let right = CGRect(x: 730, y: 10, width: 700, height: 850)

    private func area(_ rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    private func allRects(_ regions: [FocusDimDisplay]) -> [CGRect] {
        regions.flatMap { $0.windows.flatMap(\.rects) }
    }

    // MARK: rect subtraction

    func testSubtractingADisjointHoleKeepsTheRect() {
        let base = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(subtractRect(base, CGRect(x: 200, y: 0, width: 10, height: 10)), [base])
    }

    func testSubtractingACoveringHoleLeavesNothing() {
        let base = CGRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertEqual(subtractRect(base, CGRect(x: 0, y: 0, width: 200, height: 200)), [])
    }

    func testSubtractingAnInnerHoleLeavesFourPiecesWithTheRightArea() {
        let base = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pieces = subtractRect(base, CGRect(x: 25, y: 25, width: 50, height: 50))
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(area(pieces), 100 * 100 - 50 * 50, accuracy: 0.001)
        for (index, piece) in pieces.enumerated() {
            for other in pieces[(index + 1)...] {
                XCTAssertTrue(piece.intersection(other).isEmpty || piece.intersection(other).width * piece.intersection(other).height == 0)
            }
        }
    }

    // MARK: regions

    func testUnfocusedTiledWindowIsDimmedAndTheFocusedOneIsNot() {
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: right)],
            frontToBack: [ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: right)],
            displays: [display]
        )
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].display, display)
        XCTAssertEqual(regions[0].windows, [FocusDimWindowRegion(bounds: right, rects: [right])])
    }

    func testWindowsInFrontCutHolesAndThePartBehindTheFocusedWindowIsLit() {
        // An unmanaged popover-like window of another app overlaps the right
        // window; the focused window overlaps its left edge.
        let popup = CGRect(x: 900, y: 300, width: 200, height: 200)
        let focused = CGRect(x: 10, y: 10, width: 800, height: 850)
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: focused),
            windows: [DimWindow(pid: 2, frame: right)],
            frontToBack: [
                ServerWindow(pid: 9, bounds: popup), ServerWindow(pid: 1, bounds: focused),
                ServerWindow(pid: 2, bounds: right),
            ],
            displays: [display]
        )
        let rects = allRects(regions)
        let expected = right.width * right.height - popup.width * popup.height
            - right.intersection(focused).width * right.intersection(focused).height
        XCTAssertEqual(area(rects), expected, accuracy: 0.001)
        for rect in rects {
            XCTAssertTrue(rect.intersection(popup).isEmpty || rect.intersection(popup).width * rect.intersection(popup).height == 0)
            XCTAssertTrue(rect.intersection(focused).isEmpty || rect.intersection(focused).width * rect.intersection(focused).height == 0)
        }
    }

    func testTheFocusedWindowIsNeverDimmedEvenWhenBehindAnotherWindow() {
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: left)],
            frontToBack: [ServerWindow(pid: 2, bounds: left), ServerWindow(pid: 1, bounds: left)],
            displays: [display]
        )
        XCTAssertEqual(allRects(regions), [])
    }

    func testWindowsBehindTheCandidateDoNotCutHoles() {
        let floating = CGRect(x: 800, y: 100, width: 200, height: 200)
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: right)],
            frontToBack: [
                ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: right),
                ServerWindow(pid: 3, bounds: floating),
            ],
            displays: [display]
        )
        XCTAssertEqual(allRects(regions), [right])
    }

    func testParkedSliverAndUnlistedWindowsContributeNothing() {
        let parked = CGRect(x: 1439, y: 10, width: 700, height: 850)
        let minimized = CGRect(x: 730, y: 10, width: 700, height: 850)
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: parked), DimWindow(pid: 3, frame: minimized)],
            frontToBack: [ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: parked)],
            displays: [display]
        )
        XCTAssertEqual(regions, [])
    }

    func testDimsTheBoundsTheWindowServerDrawsWhenCloseToGiosFrame() {
        let drawn = right.offsetBy(dx: 2, dy: -1)
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: right)],
            frontToBack: [ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: drawn)],
            displays: [display]
        )
        XCTAssertEqual(regions.first?.windows.first?.bounds, drawn)
    }

    func testNothingIsDimmedWithoutAVisibleFocusedWindow() {
        let windows = [DimWindow(pid: 2, frame: right)]
        let server = [ServerWindow(pid: 2, bounds: right)]
        XCTAssertEqual(focusDimRegions(focused: nil, windows: windows, frontToBack: server, displays: [display]), [])
        XCTAssertEqual(
            focusDimRegions(
                focused: DimWindow(pid: 1, frame: left), windows: windows, frontToBack: server, displays: [display]
            ),
            []
        )
    }

    func testRegionsAreSplitAndClippedPerDisplay() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let straddling = CGRect(x: 1000, y: 10, width: 800, height: 850)
        let onSecond = CGRect(x: 2000, y: 10, width: 700, height: 850)
        let regions = focusDimRegions(
            focused: DimWindow(pid: 1, frame: left),
            windows: [DimWindow(pid: 2, frame: straddling), DimWindow(pid: 3, frame: onSecond)],
            frontToBack: [
                ServerWindow(pid: 1, bounds: left), ServerWindow(pid: 2, bounds: straddling),
                ServerWindow(pid: 3, bounds: onSecond),
            ],
            displays: [display, second]
        )
        XCTAssertEqual(regions.map(\.display), [display, second])
        XCTAssertEqual(allRects([regions[0]]), [CGRect(x: 1000, y: 10, width: 440, height: 850)])
        XCTAssertEqual(
            Set(allRects([regions[1]]).map { "\($0)" }),
            Set([CGRect(x: 1440, y: 10, width: 360, height: 850), onSecond].map { "\($0)" })
        )
        XCTAssertEqual(regions[1].regionCount, 2)
    }

    // MARK: timing

    func testDecisionSuppressesDuringMotionAndWaitsForTheMouse() {
        XCTAssertEqual(focusDimDecision(indicator: .dim, activity: FocusDimActivity()), .compute)
        XCTAssertEqual(focusDimDecision(indicator: .ring, activity: FocusDimActivity()), .hide(.disabled))
        XCTAssertEqual(focusDimDecision(indicator: .none, activity: FocusDimActivity()), .hide(.disabled))
        XCTAssertEqual(focusDimDecision(indicator: .dim, activity: FocusDimActivity(motion: true)), .hide(.motion))
        XCTAssertEqual(focusDimDecision(indicator: .dim, activity: FocusDimActivity(flight: true)), .hide(.motion))
        XCTAssertEqual(focusDimDecision(indicator: .dim, activity: FocusDimActivity(nativeZoom: true)), .hide(.zoom))
        XCTAssertEqual(
            focusDimDecision(indicator: .dim, activity: FocusDimActivity(mouseDown: true)), .retryAfterRelease
        )
        XCTAssertEqual(
            focusDimDecision(indicator: .dim, activity: FocusDimActivity(motion: true, mouseDown: true)),
            .hide(.motion)
        )
    }

    func testAUserDragHoldsTheDimUntilTheSnapBackReflow() {
        XCTAssertEqual(focusDimDecision(indicator: .dim, activity: FocusDimActivity(dragHeld: true)), .hide(.drag))
        XCTAssertEqual(
            focusDimDecision(indicator: .dim, activity: FocusDimActivity(mouseDown: true, dragHeld: true)),
            .hide(.drag)
        )
    }

    func testHideReasonsHaveLogNames() {
        XCTAssertEqual(FocusDimHideReason.motion.rawValue, "motion")
        XCTAssertEqual(FocusDimHideReason.drag.rawValue, "drag")
        XCTAssertEqual(FocusDimState.shown(regions: [], strength: 0.15).logLine, "focus dim shown regions=0")
        XCTAssertEqual(FocusDimState.hidden(.drag).logLine, "focus dim hidden reason=drag")
    }

    // MARK: drawing helpers

    func testAlphaFollowsStrengthAndIsSlightlyLowerInDarkMode() {
        XCTAssertEqual(focusDimAlpha(strength: 0.15, darkAppearance: false), 0.15, accuracy: 0.0001)
        XCTAssertEqual(focusDimAlpha(strength: 0.15, darkAppearance: true), 0.12, accuracy: 0.0001)
        XCTAssertEqual(focusDimAlpha(strength: 0.9, darkAppearance: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(focusDimAlpha(strength: -1, darkAppearance: false), 0, accuracy: 0.0001)
    }

    func testFadeDurationsRespectReduceMotion() {
        XCTAssertEqual(focusDimFadeDuration(showing: true, reduceMotion: false), 0.15, accuracy: 0.0001)
        XCTAssertEqual(focusDimFadeDuration(showing: false, reduceMotion: false), 0.08, accuracy: 0.0001)
        XCTAssertEqual(focusDimFadeDuration(showing: true, reduceMotion: true), 0)
        XCTAssertEqual(focusDimFadeDuration(showing: false, reduceMotion: true), 0)
    }

    // MARK: config

    func testDefaultsAreDimAtFifteenPercent() {
        let focus = defaultGioConfig().focus
        XCTAssertEqual(focus.indicator, .dim)
        XCTAssertEqual(focus.dimStrength, 0.15, accuracy: 0.0001)
    }

    func testParsesIndicatorAndStrength() throws {
        let (config, warnings) = try parseGioConfig("[focus]\nindicator = \"ring\"\ndim-strength = 0.3\n").get()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.focus.indicator, .ring)
        XCTAssertEqual(config.focus.dimStrength, 0.3, accuracy: 0.0001)
    }

    func testStrengthIsClampedWithAWarning() throws {
        let (config, warnings) = try parseGioConfig("[focus]\ndim-strength = 0.8\n").get()
        XCTAssertEqual(config.focus.dimStrength, 0.5, accuracy: 0.0001)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("focus.dim-strength"))
    }

    func testInvalidValuesAreErrorsNamingTheLine() {
        for (text, fragment) in [
            ("[focus]\nindicator = \"glow\"\n", "focus.indicator expects \"dim\", \"ring\" or \"none\""),
            ("[focus]\nindicator = 1\n", "focus.indicator expects \"dim\", \"ring\" or \"none\""),
            ("[focus]\ndim-strength = \"dark\"\n", "focus.dim-strength expects a number"),
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
        let (_, warnings) = try parseGioConfig("[focus]\nglow = true\n").get()
        XCTAssertEqual(warnings, ["line 2: unknown focus key 'glow', ignored"])
    }

    func testTemplateDocumentsTheSectionAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("[focus]"))
        XCTAssertTrue(template.contains("indicator = \"dim\""))
        let (config, warnings) = try parseGioConfig(template).get()
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.focus, FocusSectionConfig())
    }

    func testRingOnlyShowsWhenItIsTheIndicator() {
        XCTAssertTrue(FocusSectionConfig(indicator: .ring).showsRing)
        XCTAssertFalse(FocusSectionConfig(indicator: .dim).showsRing)
        XCTAssertFalse(FocusSectionConfig(indicator: .none).showsRing)
    }

    // MARK: settings form

    func testFormValidatesAndRoundTripsThroughThePatcher() throws {
        var form = FocusSettingsForm(config: FocusSectionConfig())
        XCTAssertEqual(form.problems, [])
        form.dimStrength = 0.6
        XCTAssertEqual(form.problems.count, 1)
        form.dimStrength = 0.25
        form.indicator = .none
        let result = try patchGioConfig(defaultConfigTemplate(), edits: form.edits).get()
        XCTAssertEqual(result.config.focus.indicator, FocusIndicatorKind.none)
        XCTAssertEqual(result.config.focus.dimStrength, 0.25, accuracy: 0.0001)
        let created = try patchGioConfig("[layout]\ngaps = 8\n", edits: form.edits).get()
        XCTAssertTrue(created.text.contains("[focus]"))
    }
}
