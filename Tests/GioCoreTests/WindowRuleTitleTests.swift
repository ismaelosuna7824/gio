import XCTest
@testable import GioCore

/// WR-01: the `title` matcher (a case-insensitive regex on the window
/// title, compared in memory only) and the outcome of the richer rule keys.
final class WindowRuleTitleTests: XCTestCase {
    private func pattern(_ text: String) -> TitlePattern {
        TitlePattern(text)!
    }

    private func window(
        _ element: UInt64, app: String = "Safari", title: String = "", mode: WindowMode = .tiled,
        floatReason: FloatReason? = nil, widthLimits: ColumnWidthLimits? = nil
    ) -> ManagedWindow {
        var window = ManagedWindow(
            id: WindowID(pid: 10, elementID: element), pid: 10, application: app, title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: mode, floatReason: floatReason
        )
        window.widthLimits = widthLimits
        return window
    }

    // MARK: Pattern

    func testPatternRejectsInvalidRegexAndEmptyText() {
        XCTAssertNil(TitlePattern("("))
        XCTAssertNil(TitlePattern("[a-"))
        XCTAssertNil(TitlePattern(""))
        XCTAssertEqual(TitlePattern("^Picture")?.pattern, "^Picture")
    }

    func testPatternIsCaseInsensitiveByDefault() {
        XCTAssertTrue(pattern("picture").matches("PICTURE in Picture"))
        XCTAssertTrue(pattern("^Pic").matches("picture in picture"))
        XCTAssertFalse(pattern("^in").matches("Picture in Picture"), "anchors still apply")
        XCTAssertFalse(pattern("(?-i)picture").matches("Picture"), "inline flags opt out")
    }

    func testPatternsCompareByText() {
        XCTAssertEqual(TitlePattern("a.b"), TitlePattern("a.b"))
        XCTAssertNotEqual(TitlePattern("a.b"), TitlePattern("A.B"))
    }

    // MARK: Matching

    func testTitleNarrowsTheAppMatch() {
        let rules = [WindowRule(app: "Safari", title: pattern("^Picture"), mode: .floating)]
        XCTAssertEqual(evaluateRules(rules, app: "Safari", title: "Picture in Picture").mode, .floating)
        XCTAssertEqual(evaluateRules(rules, app: "Safari", title: "GitHub"), .none)
        XCTAssertEqual(evaluateRules(rules, app: "Chrome", title: "Picture in Picture"), .none)
    }

    func testTitleNarrowsTheBundleMatch() {
        let rules = [WindowRule(app: "", bundleID: "com.apple.Safari", title: pattern("Picture"), mode: .floating)]
        XCTAssertEqual(
            evaluateRules(rules, app: "Safari", bundleID: "com.apple.Safari", title: "picture").mode, .floating
        )
        XCTAssertEqual(evaluateRules(rules, app: "Safari", bundleID: "com.other", title: "Picture"), .none)
    }

    func testTitleOnlyRuleMatchesAnyApp() {
        let rules = [WindowRule(app: "", title: pattern("Meeting"), mode: .floating)]
        XCTAssertEqual(evaluateRules(rules, app: "zoom.us", title: "Zoom Meeting").mode, .floating)
        XCTAssertEqual(evaluateRules(rules, app: "Teams", bundleID: "com.microsoft.teams2", title: "meeting").mode, .floating)
        XCTAssertEqual(evaluateRules(rules, app: "Teams", title: "Chat"), .none)
    }

    func testNoTitleNeverMatchesATitleRule() {
        let rules = [
            WindowRule(app: "Safari", title: pattern(".*"), mode: .floating),
            WindowRule(app: "Safari", workspace: 2),
        ]
        XCTAssertEqual(evaluateRules(rules, app: "Safari", title: nil), RuleOutcome(workspace: 2))
        XCTAssertEqual(evaluateRules(rules, app: "Safari", title: ""), RuleOutcome(workspace: 2))
        XCTAssertEqual(evaluateRules(rules, app: "Safari", title: "x").mode, .floating)
    }

    func testFirstMatchStillWinsEntirely() {
        let rules = [
            WindowRule(app: "Safari", title: pattern("Picture"), mode: .floating),
            WindowRule(app: "Safari", mode: .tiled, workspace: 3, openMaximized: true),
        ]
        let outcome = evaluateRules(rules, app: "Safari", title: "Picture")
        XCTAssertEqual(outcome.mode, .floating)
        XCTAssertNil(outcome.workspace)
        XCTAssertFalse(outcome.openMaximized, "later rules never merge")
        XCTAssertTrue(outcome.matchedByTitle)
        XCTAssertFalse(evaluateRules(rules, app: "Safari", title: "Other").matchedByTitle)
    }

    func testOutcomeCarriesTheNewKeys() {
        let rules = [WindowRule(
            app: "Code", columnWidth: .proportion(0.5), openMaximized: true, openOnDisplay: 2,
            openFocused: false, minWidth: 400, maxWidth: 900
        )]
        let outcome = evaluateRules(rules, app: "Code")
        XCTAssertEqual(outcome.columnWidth, .proportion(0.5))
        XCTAssertTrue(outcome.openMaximized)
        XCTAssertEqual(outcome.display, 2)
        XCTAssertFalse(outcome.openFocused)
        XCTAssertEqual(outcome.widthLimits, ColumnWidthLimits(min: 400, max: 900))
        XCTAssertTrue(evaluateRules([], app: "Code").openFocused, "default: the new window takes focus")
        XCTAssertNil(evaluateRules([WindowRule(app: "Code")], app: "Code").widthLimits)
    }

    // MARK: Reload

    func testReloadMatchesFloatRulesOnTheCurrentTitle() {
        let rules = [WindowRule(app: "Safari", title: pattern("Picture"), mode: .floating)]
        let windows = [
            window(1, title: "Picture in Picture"),
            window(2, title: "GitHub"),
            window(3, title: "Docs", mode: .floating, floatReason: .rule),
        ]
        XCTAssertEqual(reevaluateRules(rules, windows: windows), [
            .float(windows[0].id), .tile(windows[2].id),
        ])
    }

    func testReloadReappliesWidthLimits() {
        let rules = [WindowRule(app: "Safari", minWidth: 400)]
        let windows = [
            window(1),
            window(2, widthLimits: ColumnWidthLimits(min: 400, max: nil)),
            window(3, app: "Mail", widthLimits: ColumnWidthLimits(min: nil, max: 700)),
        ]
        XCTAssertEqual(reevaluateRules(rules, windows: windows), [
            .widthLimits(windows[0].id, ColumnWidthLimits(min: 400, max: nil)),
            .widthLimits(windows[2].id, nil),
        ])
    }
}
