import GioCore
import XCTest
@testable import GioUI

/// WR-06: rule rows show every rule key, and the editor's display picker
/// lists the connected displays (shown with more than one).
final class RulePresentationTests: XCTestCase {
    func testTitleRuleRowNamesTheAppAndThePattern() {
        let row = RuleRowPresentation(rule: WindowRule(app: "Safari", title: TitlePattern("^Picture"), mode: .floating))
        XCTAssertEqual(row.title, "Safari")
        XCTAssertEqual(row.subtitle, "Title matches ^Picture")
        XCTAssertEqual(row.accessibilityLabel, "Safari, title matches ^Picture: floating")
    }

    func testTitleOnlyAndBundleRulesHaveATitle() {
        XCTAssertEqual(RuleRowPresentation(rule: WindowRule(app: "", title: TitlePattern("Meet"))).title, "Any app")
        XCTAssertEqual(
            RuleRowPresentation(rule: WindowRule(app: "", bundleID: "com.apple.Safari")).title, "com.apple.Safari"
        )
        XCTAssertNil(RuleRowPresentation(rule: WindowRule(app: "Notes")).subtitle)
    }

    func testOptionBadgesListTheOpeningKeys() {
        let row = RuleRowPresentation(rule: WindowRule(
            app: "Code", columnWidth: .proportion(0.5), openMaximized: true, openOnDisplay: 2,
            openFocused: false, minWidth: 400, maxWidth: 1200
        ))
        XCTAssertEqual(row.optionBadges.map(\.label), [
            "Width 0.5", "Maximized", "Display 2", "Opens unfocused", "400–1200 pt",
        ])
        XCTAssertEqual(row.accessibilityLabel, "Code: width 0.5, maximized, display 2, opens unfocused, 400–1200 pt")
        XCTAssertFalse(row.isEmpty)
    }

    func testWidthBadgesUsePointsOrFractions() {
        XCTAssertEqual(
            RuleRowPresentation(rule: WindowRule(app: "A", columnWidth: .points(900))).optionBadges.map(\.label),
            ["Width 900 pt"]
        )
        XCTAssertEqual(
            RuleRowPresentation(rule: WindowRule(app: "A", minWidth: 500)).optionBadges.map(\.label), ["Min 500 pt"]
        )
        XCTAssertEqual(
            RuleRowPresentation(rule: WindowRule(app: "A", maxWidth: 800)).optionBadges.map(\.label), ["Max 800 pt"]
        )
    }

    func testRowWithoutAnyOpinionIsEmpty() {
        XCTAssertTrue(RuleRowPresentation(rule: WindowRule(app: "Notes")).isEmpty)
        XCTAssertFalse(RuleRowPresentation(rule: WindowRule(app: "Notes", mode: .tiled)).isEmpty)
    }

    func testDisplayPickerOptions() {
        XCTAssertFalse(ruleShowsDisplayPicker(displayCount: 1, current: nil))
        XCTAssertTrue(ruleShowsDisplayPicker(displayCount: 2, current: nil))
        XCTAssertTrue(ruleShowsDisplayPicker(displayCount: 1, current: 3), "a saved display stays editable")
        XCTAssertEqual(ruleDisplayOptions(displayCount: 2, current: nil).map(\.1), ["Focused display", "Display 1", "Display 2"])
        XCTAssertEqual(ruleDisplayOptions(displayCount: 2, current: 4).map(\.0), [nil, 1, 2, 4])
    }

    func testWidthLimitFieldText() {
        XCTAssertNil(ruleWidthLimitValue("  "))
        XCTAssertEqual(ruleWidthLimitValue(" 640 "), 640)
        XCTAssertTrue(ruleWidthLimitValue("wide")?.isNaN ?? false, "the form reports it")
        XCTAssertEqual(ruleWidthLimitText(nil), "")
        XCTAssertEqual(ruleWidthLimitText(1200), "1200")
        XCTAssertEqual(ruleWidthLimitText(812.5), "812.5")
    }

    func testWorkspaceCardsIgnoreTitleRules() throws {
        var config = defaultGioConfig()
        config.workspaces = [WorkspaceDefinition(name: "Code")]
        config.rules = [
            WindowRule(app: "Safari", title: TitlePattern("Docs"), openOnWorkspace: "Code"),
            WindowRule(app: "Mail", openOnWorkspace: "Code", openMaximized: true),
        ]
        let draft = WorkspacesDraft(config: config)
        XCTAssertEqual(draft.cards[0].apps.map(\.app), ["Mail"], "a title rule is narrower than the app")
        var emptied = draft
        emptied.cards[0].apps = []
        let edits = workspaceConfigEdits(config: config, draft: emptied)
        XCTAssertFalse(edits.contains(.removeRule(index: 0)), "the title rule is not the card's to remove")
        XCTAssertFalse(edits.contains(.removeRule(index: 1)), "a rule with other opinions keeps them")
        var kept = config.rules[1]
        kept.openOnWorkspace = nil
        XCTAssertTrue(edits.contains(.updateRule(index: 1, kept)))
    }
}
