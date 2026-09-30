import GioCore
import XCTest
@testable import GioUI

/// NW-03 pure logic behind the Workspaces section: cards from config, app
/// assignment (unique, moves), reorder, validation, and the config edits a
/// draft turns into (round-tripped through the real patcher and parser).
final class WorkspacesPresentationTests: XCTestCase {
    private let safari = WorkspaceAppAssignment(app: "Safari", bundleID: "com.apple.Safari")
    private let chrome = WorkspaceAppAssignment(app: "Google Chrome", bundleID: "com.google.Chrome")
    private let code = WorkspaceAppAssignment(app: "Code", bundleID: "com.microsoft.VSCode")

    private func config(_ text: String) throws -> GioConfig {
        switch parseGioConfig(text) {
        case .success(let parsed): return parsed.0
        case .failure(let errors): throw XCTSkip("fixture failed to parse: \(errors.messages)")
        }
    }

    private let baseText = """
    # My config
    [[workspace]]
    name = "Code"
    icon = "chevron.left.forwardslash.chevron.right"
    color = "#5e9eff"

    [[workspace]]
    name = "Browsers"
    icon = "globe"

    [[window-rules]]
    app = "Code"
    bundle-id = "com.microsoft.VSCode"
    open-on-workspace = "Code"

    [[window-rules]]
    app = "Safari"
    bundle-id = "com.apple.Safari"
    open-on-workspace = "Browsers"
    follow = "always"

    [[window-rules]]
    app = "Figma"
    mode = "floating"
    """

    /// Applies the draft's edits to `text` and returns the patched config.
    private func roundTrip(_ text: String, _ draft: WorkspacesDraft) throws -> PatchedConfig {
        let config = try config(text)
        let edits = workspaceConfigEdits(config: config, draft: draft)
        switch patchGioConfig(text, edits: edits) {
        case .success(let patched): return patched
        case .failure(let errors):
            XCTFail("patch failed: \(errors.messages)")
            throw errors
        }
    }

    // MARK: - Cards from config

    func testCardsFollowConfigOrderWithTheirApps() throws {
        let draft = WorkspacesDraft(config: try config(baseText))
        XCTAssertEqual(draft.cards.map(\.name), ["Code", "Browsers"])
        XCTAssertEqual(draft.cards[0].icon, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(draft.cards[0].color, "#5e9eff")
        XCTAssertEqual(draft.cards[0].apps, [code])
        XCTAssertEqual(draft.cards[1].apps, [WorkspaceAppAssignment(app: "Safari", bundleID: "com.apple.Safari", follow: .always)])
        XCTAssertEqual(draft.cards.map(\.origin), [0, 1])
    }

    func testAnAppShowsOnlyInTheFirstWorkspaceThatClaimsIt() throws {
        let draft = WorkspacesDraft(config: try config(baseText + """

        [[window-rules]]
        app = "Safari"
        bundle-id = "com.apple.Safari"
        open-on-workspace = "Code"
        """))
        XCTAssertEqual(draft.cards[0].apps.map(\.app), ["Code"])
        XCTAssertEqual(draft.cards[1].apps.map(\.app), ["Safari"])
    }

    func testSameConfigGivesEqualDrafts() throws {
        let config = try config(baseText)
        XCTAssertEqual(WorkspacesDraft(config: config), WorkspacesDraft(config: config))
    }

    // MARK: - Assignment

    func testAssigningAnAppOwnedElsewhereMovesIt() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        let codeID = draft.cards[0].id
        XCTAssertEqual(
            draft.conflicts(assigning: [safari, chrome], to: codeID),
            [WorkspaceAppConflict(app: "Safari", from: "Browsers")]
        )
        draft.assign([safari, chrome], to: codeID)
        XCTAssertEqual(draft.cards[0].apps.map(\.app), ["Code", "Safari", "Google Chrome"])
        XCTAssertTrue(draft.cards[1].apps.isEmpty)
        XCTAssertTrue(draft.conflicts(assigning: [safari], to: codeID).isEmpty, "already here: no conflict")
    }

    func testAssigningAnAppAlreadyInTheCardKeepsOneCopyAndItsFollow() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        let browsers = draft.cards[1].id
        draft.assign([safari], to: browsers)
        XCTAssertEqual(draft.cards[1].apps, [WorkspaceAppAssignment(app: "Safari", bundleID: "com.apple.Safari", follow: .always)])
    }

    func testMatchingByNameWhenABundleIDIsMissing() throws {
        var draft = WorkspacesDraft(cards: [])
        let first = draft.addWorkspace()
        let second = draft.addWorkspace()
        draft.assign([WorkspaceAppAssignment(app: "Safari")], to: first)
        XCTAssertEqual(draft.conflicts(assigning: [safari], to: second), [WorkspaceAppConflict(app: "Safari", from: "Workspace 1")])
        draft.assign([safari], to: second)
        XCTAssertTrue(draft.cards[0].apps.isEmpty)
    }

    func testFollowAndRemove() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        let codeID = draft.cards[0].id
        draft.setFollow(.never, app: code.id, in: codeID)
        XCTAssertEqual(draft.cards[0].apps.first?.follow, .never)
        draft.removeApp(code.id, from: codeID)
        XCTAssertTrue(draft.cards[0].apps.isEmpty)
    }

    // MARK: - Workspaces

    func testNewWorkspacesGetUniqueDefaultNamesAndIDs() {
        var draft = WorkspacesDraft(cards: [])
        let a = draft.addWorkspace()
        let b = draft.addWorkspace()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(draft.cards.map(\.name), ["Workspace 1", "Workspace 2"])
        XCTAssertEqual(draft.cards.map(\.origin), [nil, nil])
    }

    func testTemplatesPrefillIconAndColorWithoutApps() {
        var draft = WorkspacesDraft(cards: [])
        draft.addWorkspace(template: .code)
        draft.addWorkspace(template: .code)
        XCTAssertEqual(draft.cards.map(\.name), ["Code", "Code 2"])
        XCTAssertEqual(draft.cards[0].icon, WorkspaceTemplate.code.icon)
        XCTAssertEqual(draft.cards[0].color, WorkspaceTemplate.code.color)
        XCTAssertTrue(draft.cards[0].apps.isEmpty)
        XCTAssertEqual(WorkspaceTemplate.allCases.map(\.name), ["Code", "Browsers", "Chat", "Design"])
        for template in WorkspaceTemplate.allCases {
            XCTAssertNotNil(ThemeColor(hex: template.color), "\(template)")
        }
    }

    func testReorder() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        draft.addWorkspace(template: .chat)
        let ids = draft.cards.map(\.id)
        XCTAssertFalse(draft.canMoveUp(ids[0]))
        XCTAssertFalse(draft.canMoveDown(ids[2]))
        draft.moveDown(ids[0])
        XCTAssertEqual(draft.cards.map(\.name), ["Browsers", "Code", "Chat"])
        draft.moveUp(ids[2])
        XCTAssertEqual(draft.cards.map(\.name), ["Browsers", "Chat", "Code"])
        draft.move(ids[2], before: ids[1])
        XCTAssertEqual(draft.cards.map(\.name), ["Chat", "Browsers", "Code"])
        draft.move(ids[0], before: nil)
        XCTAssertEqual(draft.cards.map(\.name), ["Chat", "Browsers", "Code"], "nil target = end")
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(draft.cards.map(\.name), ["Code", "Chat", "Browsers"])
    }

    func testDropOntoACardTakesItsPlace() {
        var draft = WorkspacesDraft(cards: [])
        let ids = (0..<4).map { _ in draft.addWorkspace() }
        draft.drop(ids[0], onto: ids[2])
        XCTAssertEqual(draft.cards.map(\.id), [ids[1], ids[2], ids[0], ids[3]], "dragged down: lands after the target")
        draft.drop(ids[3], onto: ids[1])
        XCTAssertEqual(draft.cards.map(\.id), [ids[3], ids[1], ids[2], ids[0]], "dragged up: lands before the target")
        draft.drop(ids[2], onto: ids[2])
        XCTAssertEqual(draft.cards.map(\.id), [ids[3], ids[1], ids[2], ids[0]])
    }

    // MARK: - Validation

    func testNameValidation() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        let ids = draft.cards.map(\.id)
        XCTAssertNil(draft.nameProblem(for: ids[0]))
        draft.rename(ids[1], to: "  ")
        XCTAssertEqual(draft.nameProblem(for: ids[1]), "Give this workspace a name.")
        draft.rename(ids[1], to: "code ")
        XCTAssertEqual(draft.nameProblem(for: ids[1]), "Another workspace is already named “code”.")
        draft.rename(ids[1], to: "Say \"hi\"")
        XCTAssertEqual(draft.nameProblem(for: ids[1]), "Names can’t contain double quotes.")
        XCTAssertEqual(draft.problems, ["Names can’t contain double quotes."])
        draft.rename(ids[1], to: "Web")
        XCTAssertTrue(draft.problems.isEmpty)
    }

    // MARK: - Config edits

    func testUnchangedDraftMakesNoEdits() throws {
        let config = try config(baseText)
        XCTAssertEqual(workspaceConfigEdits(config: config, draft: WorkspacesDraft(config: config)), [])
    }

    func testNewWorkspaceWithAppsRoundTrips() throws {
        let text = "[layout]\ngaps = 8\n"
        var draft = WorkspacesDraft(config: try config(text))
        let id = draft.addWorkspace(template: .browsers)
        draft.assign([safari, chrome], to: id)
        draft.setFollow(.never, app: chrome.id, in: id)
        let patched = try roundTrip(text, draft)
        XCTAssertTrue(patched.text.contains("[layout]\ngaps = 8\n"), "unrelated lines kept")
        XCTAssertTrue(patched.text.contains("bundle-id = \"com.google.Chrome\""))
        XCTAssertTrue(patched.text.contains("app = \"Google Chrome\""), "name kept for readability")
        XCTAssertTrue(patched.text.contains("follow = \"never\""))
        XCTAssertEqual(patched.warnings, [])
        let reloaded = WorkspacesDraft(config: patched.config)
        XCTAssertEqual(reloaded.cards.map(\.name), ["Browsers"])
        XCTAssertEqual(reloaded.cards[0].icon, WorkspaceTemplate.browsers.icon)
        XCTAssertEqual(reloaded.cards[0].apps, [
            safari, WorkspaceAppAssignment(app: "Google Chrome", bundleID: "com.google.Chrome", follow: .never),
        ])
    }

    func testRenameUpdatesTheRulesThatPointAtIt() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        draft.rename(draft.cards[1].id, to: "Web")
        let patched = try roundTrip(baseText, draft)
        XCTAssertEqual(patched.warnings, [])
        XCTAssertTrue(patched.text.hasPrefix("# My config\n"), "comments kept")
        let reloaded = WorkspacesDraft(config: patched.config)
        XCTAssertEqual(reloaded.cards.map(\.name), ["Code", "Web"])
        XCTAssertEqual(reloaded.cards[1].apps.map(\.app), ["Safari"])
        XCTAssertEqual(reloaded.cards[1].apps.first?.follow, .always)
    }

    func testDeletingAWorkspaceDropsItsAssignmentsButKeepsOtherOpinions() throws {
        let text = baseText + """

        [[window-rules]]
        app = "Arc"
        mode = "floating"
        open-on-workspace = "Browsers"
        """
        var draft = WorkspacesDraft(config: try config(text))
        draft.removeWorkspace(draft.cards[1].id)
        let patched = try roundTrip(text, draft)
        XCTAssertEqual(patched.warnings, [])
        XCTAssertEqual(patched.config.workspaces.map(\.name), ["Code"])
        XCTAssertFalse(patched.text.contains("com.apple.Safari"), "assignment-only rule removed")
        let arc = patched.config.rules.first { $0.app == "Arc" }
        XCTAssertEqual(arc?.mode, .floating, "the floating opinion stays")
        XCTAssertNil(arc?.openOnWorkspace)
        XCTAssertEqual(patched.config.rules.first { $0.app == "Figma" }?.mode, .floating)
    }

    func testAssigningAnAppWithAnExistingRuleUpdatesThatRule() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        draft.assign([WorkspaceAppAssignment(app: "Figma", bundleID: "com.figma.Desktop")], to: draft.cards[0].id)
        let patched = try roundTrip(baseText, draft)
        let figma = patched.config.rules.filter { $0.app == "Figma" }
        XCTAssertEqual(figma.count, 1, "no second rule the first would shadow")
        XCTAssertEqual(figma.first?.mode, .floating)
        XCTAssertEqual(figma.first?.openOnWorkspace, "Code")
        XCTAssertEqual(figma.first?.bundleID, "com.figma.Desktop")
    }

    func testMovingAnAppBetweenWorkspacesRewritesItsRule() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        draft.assign([safari], to: draft.cards[0].id)
        let patched = try roundTrip(baseText, draft)
        let safariRules = patched.config.rules.filter { $0.bundleID == "com.apple.Safari" }
        XCTAssertEqual(safariRules.count, 1)
        XCTAssertEqual(safariRules.first?.openOnWorkspace, "Code")
        XCTAssertEqual(safariRules.first?.follow, .always)
    }

    func testReorderAndEditRoundTrip() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        let chat = draft.addWorkspace(template: .chat)
        draft.move(chat, before: draft.cards[0].id)
        draft.moveDown(draft.cards[1].id)
        draft.cards[2].color = "#34c3a0"
        draft.cards[2].display = .index(2)
        let patched = try roundTrip(baseText, draft)
        XCTAssertEqual(patched.config.workspaces.map(\.name), ["Chat", "Browsers", "Code"])
        XCTAssertEqual(patched.config.workspaces[2].color, "#34c3a0")
        XCTAssertEqual(patched.config.workspaces[2].display, .index(2))
        XCTAssertEqual(WorkspacesDraft(config: patched.config).cards.map(\.name), ["Chat", "Browsers", "Code"])
    }

    func testRemovingEveryWorkspaceRoundTrips() throws {
        var draft = WorkspacesDraft(config: try config(baseText))
        for id in draft.cards.map(\.id) {
            draft.removeWorkspace(id)
        }
        let patched = try roundTrip(baseText, draft)
        XCTAssertTrue(patched.config.workspaces.isEmpty)
        XCTAssertEqual(patched.config.rules.map(\.app), ["Figma"])
    }

    // MARK: - Small presentation

    func testShortcutSummary() {
        var draft = WorkspacesDraft(cards: [])
        XCTAssertEqual(workspaceShortcutSummary(draft), "")
        draft.addWorkspace(template: .code)
        draft.addWorkspace(template: .browsers)
        XCTAssertEqual(workspaceShortcutSummary(draft), "⌥1 Code · ⌥2 Browsers · ⌥3 and up: other workspaces")
    }

    func testSymbolSearchMatchesNamesAndKeywords() {
        XCTAssertEqual(filterWorkspaceSymbols(""), workspaceSymbolCatalog.map(\.name))
        XCTAssertTrue(filterWorkspaceSymbols("web").contains("globe"))
        XCTAssertTrue(filterWorkspaceSymbols("GLOBE").contains("globe"))
        XCTAssertEqual(filterWorkspaceSymbols("zzzz"), [])
        XCTAssertEqual(Set(workspaceSymbolCatalog.map(\.name)).count, workspaceSymbolCatalog.count, "no duplicates")
        for template in WorkspaceTemplate.allCases {
            XCTAssertTrue(workspaceSymbolCatalog.contains { $0.name == template.icon }, "\(template)")
        }
    }

    func testDisplayOptions() {
        XCTAssertEqual(workspaceDisplayOptions(displayCount: 1, current: nil).map(\.1), ["Main"])
        XCTAssertEqual(workspaceDisplayOptions(displayCount: 3, current: nil).map(\.1), ["Main", "Display 2", "Display 3"])
        XCTAssertEqual(
            workspaceDisplayOptions(displayCount: 1, current: .index(3)).map(\.1), ["Main", "Display 3"],
            "a disconnected display stays selectable"
        )
    }

    func testRuleRowShowsTheNamedWorkspace() {
        let row = RuleRowPresentation(rule: WindowRule(app: "Safari", openOnWorkspace: "Browsers", follow: .always))
        XCTAssertEqual(row.workspaceBadge, RuleBadge(label: "Browsers", symbol: "square.stack.3d.up.fill", kind: .info))
        XCTAssertEqual(row.accessibilityLabel, "Safari: workspace Browsers")
    }
}
