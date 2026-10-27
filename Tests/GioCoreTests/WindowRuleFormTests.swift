import XCTest
@testable import GioCore

/// WR-06: the Rules form edits every rule key with the file's validation,
/// and form -> rule -> config text -> rule round-trips. In-memory text only.
final class WindowRuleFormTests: XCTestCase {
    private let richRules: [WindowRule] = [
        WindowRule(app: "Safari", title: TitlePattern("^Picture in Picture$"), mode: .floating),
        WindowRule(app: "", title: TitlePattern("\\bMeet\\b"), openFocused: false),
        WindowRule(app: "Code", columnWidth: .proportion(0.66667), openMaximized: true, minWidth: 400, maxWidth: 1400),
        WindowRule(app: "Mail", workspace: 3, columnWidth: .points(900), openOnDisplay: 2),
        WindowRule(app: "", bundleID: "com.tinyspeck.slackmacgap", follow: .never, openMaximized: true),
        // FL-01: an explicit `open-focused = true` survives form and file.
        WindowRule(app: "Slack", openFocused: true),
    ]

    func testFormRoundTripsEveryKey() {
        for rule in richRules {
            let form = RuleForm(rule: rule)
            XCTAssertEqual(form.problems, [], "\(rule)")
            XCTAssertEqual(form.rule, rule)
        }
    }

    func testPatchedRulesParseBackIdentically() throws {
        for rule in richRules {
            guard case .success(let patched) = patchGioConfig("", edits: [.addRule(rule)]) else {
                return XCTFail("patch failed for \(rule)")
            }
            XCTAssertEqual(patched.config.rules, [rule], patched.text)
        }
    }

    func testTitleOnlyRulesWriteNoEmptyApp() throws {
        guard case .success(let patched) = patchGioConfig(
            "", edits: [.addRule(WindowRule(app: "", title: TitlePattern("Meet")))]
        ) else {
            return XCTFail("patch failed")
        }
        XCTAssertFalse(patched.text.contains("app = "))
        XCTAssertTrue(patched.text.contains("title = \"Meet\""))
    }

    func testTitleAloneIsEnough() {
        var form = RuleForm()
        XCTAssertEqual(form.problems, ["App name or title pattern is required."])
        form.title = "Meet"
        XCTAssertEqual(form.problems, [])
        XCTAssertEqual(form.rule, WindowRule(app: "", title: TitlePattern("Meet")))
    }

    func testTitleValidationMatchesTheFile() {
        var form = RuleForm(app: "Safari")
        form.title = "(unclosed"
        XCTAssertEqual(form.problems, ["Title pattern is not a valid regular expression."])
        form.title = "say \"hi\""
        XCTAssertEqual(form.problems, ["Title pattern cannot contain a double quote."])
        form.title = ""
        XCTAssertNil(form.rule.title, "an empty field means no title matcher")
    }

    func testWidthValidationMatchesTheFile() {
        var form = RuleForm(app: "Code")
        form.widthChoice = .fraction
        form.widthValue = 1.5
        XCTAssertEqual(form.problems, ["Width fraction must be more than 0 and at most 1."])
        form.widthValue = 0.5
        XCTAssertEqual(form.rule.columnWidth, .proportion(0.5))
        form.widthChoice = .points
        XCTAssertEqual(form.problems, ["Width in points must be more than 1."])
        form.widthValue = 800
        XCTAssertEqual(form.rule.columnWidth, .points(800))
        form.widthChoice = .layoutDefault
        XCTAssertNil(form.rule.columnWidth)
    }

    func testSwitchingTheWidthUnitKeepsAUsableValue() {
        var form = RuleForm(app: "Code")
        form.adoptWidthChoice(.points)
        XCTAssertEqual(form.widthValue, 800)
        form.adoptWidthChoice(.fraction)
        XCTAssertEqual(form.widthValue, 0.5)
        form.widthValue = 0.4
        form.adoptWidthChoice(.layoutDefault)
        form.adoptWidthChoice(.fraction)
        XCTAssertEqual(form.widthValue, 0.4)
        XCTAssertEqual(form.problems, [])
    }

    func testWidthLimitValidationMatchesTheFile() {
        var form = RuleForm(app: "Code")
        form.minWidth = 0.5
        XCTAssertEqual(form.problems, ["Minimum width must be more than 1 point."])
        form.minWidth = 900
        form.maxWidth = 400
        XCTAssertEqual(form.problems, ["Minimum width cannot be above the maximum width."])
        form.maxWidth = 0
        XCTAssertEqual(form.problems, ["Maximum width must be more than 1 point."])
        form.maxWidth = 1200
        XCTAssertEqual(form.problems, [])
        XCTAssertEqual(form.rule.minWidth, 900)
        XCTAssertEqual(form.rule.maxWidth, 1200)
    }

    func testDisplayAndTogglesReachTheRule() {
        var form = RuleForm(app: "Mail")
        form.openOnDisplay = 2
        form.openMaximized = true
        form.openFocused = false
        let rule = form.rule
        XCTAssertEqual(rule.openOnDisplay, 2)
        XCTAssertTrue(rule.openMaximized)
        XCTAssertEqual(rule.openFocused, false)
        form.openOnDisplay = 0
        XCTAssertEqual(form.problems, ["Display must be 1 or more."])
    }
}
