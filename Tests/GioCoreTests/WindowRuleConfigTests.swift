import XCTest
@testable import GioCore

/// WR-02: parsing the richer `[[window-rules]]` keys (title, widths,
/// maximized, display, focus, width limits). In-memory text only.
final class WindowRuleConfigTests: XCTestCase {
    private func parsed(_ text: String) throws -> GioConfig {
        switch parseGioConfig(text) {
        case .success(let value):
            XCTAssertEqual(value.1, [], "no warnings expected")
            return value.0
        case .failure(let errors):
            XCTFail("parse failed: \(errors.messages)")
            throw errors
        }
    }

    private func failures(_ text: String) -> [String] {
        if case .failure(let errors) = parseGioConfig(text) {
            return errors.messages
        }
        return []
    }

    private func rule(_ body: String) -> String {
        "[[window-rules]]\n" + body + "\n"
    }

    func testEveryNewKeyParses() throws {
        let config = try parsed(rule("""
        app = "Safari"
        title = "^Picture in Picture$"
        default-column-width = 0.5
        open-maximized = true
        open-on-display = 2
        open-focused = false
        min-width = 400
        max-width = 1200.5
        """))
        XCTAssertEqual(config.rules, [WindowRule(
            app: "Safari", title: TitlePattern("^Picture in Picture$"), columnWidth: .proportion(0.5),
            openMaximized: true, openOnDisplay: 2, openFocused: false, minWidth: 400, maxWidth: 1200.5
        )])
    }

    func testDefaultsKeepTheOldBehaviour() throws {
        let rule = try parsed(rule("app = \"Notes\"")).rules[0]
        XCTAssertNil(rule.title)
        XCTAssertNil(rule.columnWidth)
        XCTAssertFalse(rule.openMaximized)
        XCTAssertNil(rule.openOnDisplay)
        XCTAssertNil(rule.openFocused, "unset: tiled arrivals take focus, popups do not")
        XCTAssertNil(rule.minWidth)
        XCTAssertNil(rule.maxWidth)
    }

    /// FL-01: an explicit `open-focused = true` is kept apart from unset, so
    /// it can opt a background app's popups in.
    func testExplicitOpenFocusedTrueIsKept() throws {
        let rule = try parsed(rule("app = \"Slack\"\nopen-focused = true")).rules[0]
        XCTAssertEqual(rule.openFocused, true)
    }

    func testTitleAloneIsAValidRule() throws {
        let config = try parsed(rule("title = \"Meeting\"\nmode = \"floating\""))
        XCTAssertEqual(config.rules, [WindowRule(app: "", title: TitlePattern("Meeting"), mode: .floating)])
    }

    func testRegexBackslashesAreKeptVerbatim() throws {
        let config = try parsed(rule("app = \"Code\"\ntitle = \"\\.swift — \\w+$\""))
        XCTAssertEqual(config.rules[0].title?.pattern, "\\.swift — \\w+$")
    }

    func testWidthIsAFractionUpToOneElsePoints() throws {
        XCTAssertEqual(try parsed(rule("app = \"A\"\ndefault-column-width = 1")).rules[0].columnWidth, .proportion(1))
        XCTAssertEqual(try parsed(rule("app = \"A\"\ndefault-column-width = 800")).rules[0].columnWidth, .points(800))
    }

    func testInvalidRegexIsAnErrorThatQuotesThePattern() {
        let messages = failures(rule("app = \"A\"\ntitle = \"(unclosed\""))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasSuffix("window-rules title is not a valid regular expression: (unclosed"))
    }

    func testBadValuesAreErrors() {
        let cases: [(String, String)] = [
            ("title = \"\"", "window-rules title must be a non-empty regular expression string"),
            ("title = 3", "window-rules title must be a non-empty regular expression string"),
            ("default-column-width = 0", "window-rules default-column-width expects a positive number"),
            ("default-column-width = \"half\"", "window-rules default-column-width expects a positive number"),
            ("open-maximized = \"yes\"", "window-rules open-maximized expects true or false"),
            ("open-focused = 1", "window-rules open-focused expects true or false"),
            ("open-on-display = 0", "window-rules open-on-display expects a display number (1, 2, ...)"),
            ("open-on-display = \"main\"", "window-rules open-on-display expects a display number (1, 2, ...)"),
            ("min-width = 0.5", "window-rules min-width expects points (a number above 1)"),
            ("max-width = -3", "window-rules max-width expects points (a number above 1)"),
        ]
        for (line, message) in cases {
            let messages = failures(rule("app = \"A\"\n" + line))
            XCTAssertTrue(messages.contains { $0.contains(message) }, "\(line) -> \(messages)")
        }
    }

    func testMinAboveMaxIsAnError() {
        XCTAssertTrue(failures(rule("app = \"A\"\nmin-width = 900\nmax-width = 400")).contains {
            $0.contains("window-rules min-width (900) is above max-width (400)")
        })
    }

    func testARuleStillNeedsSomethingToMatch() {
        XCTAssertTrue(failures(rule("open-maximized = true")).contains {
            $0.contains("window-rules needs a non-empty app or bundle-id string, or a title")
        })
    }

    func testCombinationsWithTheExistingKeys() throws {
        let config = try parsed("""
        [[workspace]]
        name = "Code"

        [[window-rules]]
        bundle-id = "com.microsoft.VSCode"
        title = "\\.md$"
        open-on-workspace = "Code"
        follow = "never"
        open-focused = false
        default-column-width = 0.66667
        """)
        XCTAssertEqual(config.rules, [WindowRule(
            app: "", bundleID: "com.microsoft.VSCode", title: TitlePattern("\\.md$"), openOnWorkspace: "Code",
            follow: .never, columnWidth: .proportion(0.66667), openFocused: false
        )])
    }
}
