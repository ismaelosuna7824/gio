import XCTest
@testable import GioCore

/// NW-01: `[[workspace]]` entries and `open-on-workspace` window rules.
/// In-memory text only; the user's config is never read or written.
final class NamedWorkspaceConfigTests: XCTestCase {
    private func parsed(_ text: String) throws -> (GioConfig, [String]) {
        switch parseGioConfig(text) {
        case .success(let value): return value
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

    private func patched(_ text: String, _ edits: [ConfigEdit]) throws -> PatchedConfig {
        switch patchGioConfig(text, edits: edits) {
        case .success(let value): return value
        case .failure(let errors):
            XCTFail("patch failed: \(errors.messages)")
            throw errors
        }
    }

    // MARK: - Parsing

    func testWorkspaceEntriesParseInFileOrder() throws {
        let (config, warnings) = try parsed("""
        [[workspace]]
        name = "Code"
        icon = "chevron.left.forwardslash.chevron.right"
        color = "#7fc8ff"

        [[workspace]]
        name = "Chat"
        display = "main"

        [[workspace]]
        name = "Browsers"
        display = 2
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.workspaces, [
            WorkspaceDefinition(
                name: "Code", icon: "chevron.left.forwardslash.chevron.right", color: "#7fc8ff"
            ),
            WorkspaceDefinition(name: "Chat", display: .main),
            WorkspaceDefinition(name: "Browsers", display: .index(2)),
        ])
    }

    func testNoWorkspaceTablesMeansNoNamedWorkspaces() throws {
        let (config, _) = try parsed("[layout]\ngaps = 4\n")
        XCTAssertEqual(config.workspaces, [])
        XCTAssertEqual(defaultGioConfig().workspaces, [])
    }

    func testWorkspaceValidationMessages() {
        XCTAssertTrue(failures("[[workspace]]\nicon = \"star\"\n").contains {
            $0.contains("workspace needs a non-empty name")
        })
        XCTAssertTrue(failures("[[workspace]]\nname = \"  \"\n").contains {
            $0.contains("workspace needs a non-empty name")
        })
        XCTAssertTrue(failures("[[workspace]]\nname = \"A\"\n[[workspace]]\nname = \"A\"\n").contains {
            $0.contains("duplicate workspace name 'A'")
        })
        XCTAssertTrue(failures("[[workspace]]\nname = \"A\"\ncolor = \"blue\"\n").contains {
            $0.contains("workspace color expects a hex color")
        })
        XCTAssertTrue(failures("[[workspace]]\nname = \"A\"\ndisplay = 0\n").contains {
            $0.contains("workspace display expects \"main\" or a display number")
        })
        XCTAssertTrue(failures("[[workspace]]\nname = \"A\"\ndisplay = \"left\"\n").contains {
            $0.contains("workspace display expects \"main\" or a display number")
        })
    }

    func testUnknownWorkspaceKeyWarns() throws {
        // DW-03 made `layout` a known key; `gaps` stays unknown here.
        let (config, warnings) = try parsed("[[workspace]]\nname = \"A\"\ngaps = 4\n")
        XCTAssertEqual(config.workspaces.map(\.name), ["A"])
        XCTAssertTrue(warnings.contains { $0.contains("unknown workspace key 'gaps'") })
    }

    func testRuleGainsBundleIDOpenOnWorkspaceAndFollow() throws {
        let (config, warnings) = try parsed("""
        [[workspace]]
        name = "Code"

        [[window-rules]]
        bundle-id = "com.microsoft.VSCode"
        open-on-workspace = "Code"
        follow = "always"

        [[window-rules]]
        app = "Slack"
        open-on-workspace = "Code"
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.rules, [
            WindowRule(app: "", bundleID: "com.microsoft.VSCode", openOnWorkspace: "Code", follow: .always),
            WindowRule(app: "Slack", openOnWorkspace: "Code", follow: .whenActive),
        ])
    }

    func testRuleNeedsAppOrBundleID() {
        XCTAssertTrue(failures("[[window-rules]]\nmode = \"floating\"\n").contains {
            $0.contains("window-rules needs a non-empty app or bundle-id")
        })
    }

    func testBadFollowValueIsAnError() {
        XCTAssertTrue(failures("[[window-rules]]\napp = \"A\"\nfollow = \"sometimes\"\n").contains {
            $0.contains("window-rules follow must be \"when-active\", \"always\" or \"never\"")
        })
    }

    func testUnknownOpenOnWorkspaceWarnsAndIsDropped() throws {
        let (config, warnings) = try parsed("""
        [[window-rules]]
        app = "Slack"
        mode = "floating"
        open-on-workspace = "Chat"
        """)
        XCTAssertEqual(config.rules, [WindowRule(app: "Slack", mode: .floating)])
        XCTAssertTrue(warnings.contains { $0.contains("open-on-workspace 'Chat' names no [[workspace]]") })
    }

    func testOpenOnWorkspaceWinsOverIndexWithWarning() throws {
        let (config, warnings) = try parsed("""
        [[workspace]]
        name = "Chat"

        [[window-rules]]
        app = "Slack"
        workspace = 3
        open-on-workspace = "Chat"
        """)
        XCTAssertEqual(config.rules, [WindowRule(app: "Slack", openOnWorkspace: "Chat")])
        XCTAssertTrue(warnings.contains { $0.contains("open-on-workspace wins over workspace") })
    }

    func testExistingRulesKeepTheirMeaning() throws {
        let (config, warnings) = try parsed("""
        [[window-rules]]
        app = "Calculator"
        mode = "floating"

        [[window-rules]]
        app = "Code"
        workspace = 2
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.rules, [
            WindowRule(app: "Calculator", mode: .floating),
            WindowRule(app: "Code", workspace: 2),
        ])
        XCTAssertEqual(config.rules[1].follow, .whenActive)
        XCTAssertNil(config.rules[1].bundleID)
        XCTAssertNil(config.rules[1].openOnWorkspace)
    }

    // MARK: - Matching

    func testBundleIDIsPreferredOverAppName() {
        let rules = [
            WindowRule(app: "Code", bundleID: "com.microsoft.VSCode", openOnWorkspace: "Code"),
            WindowRule(app: "Code", mode: .floating),
        ]
        XCTAssertEqual(
            evaluateRules(rules, app: "Code", bundleID: "com.microsoft.VSCode").openOnWorkspace, "Code"
        )
        // Same name, other bundle: the bundle rule does not match.
        XCTAssertEqual(evaluateRules(rules, app: "Code", bundleID: "com.other.Code").mode, .floating)
        XCTAssertNil(evaluateRules(rules, app: "Code", bundleID: "com.other.Code").openOnWorkspace)
        // Unknown bundle id: the app name still matches the bundle rule.
        XCTAssertEqual(evaluateRules(rules, app: "Code", bundleID: nil).openOnWorkspace, "Code")
    }

    func testBundleOnlyRuleNeverMatchesByEmptyName() {
        let rules = [WindowRule(app: "", bundleID: "com.x", mode: .floating)]
        XCTAssertEqual(evaluateRules(rules, app: "", bundleID: nil), .none)
        XCTAssertEqual(evaluateRules(rules, app: "X", bundleID: "com.x").mode, .floating)
    }

    func testOutcomeCarriesFollowPolicy() {
        let rules = [WindowRule(app: "Mail", openOnWorkspace: "Chat", follow: .never)]
        let outcome = evaluateRules(rules, app: "Mail")
        XCTAssertEqual(outcome.openOnWorkspace, "Chat")
        XCTAssertEqual(outcome.follow, .never)
    }

    // MARK: - Patching

    private let sample = """
    # mine
    [layout]
    gaps = 8

    [[workspace]]
    # the editor
    name = "Code"

    [[workspace]]
    name = "Chat"

    [[window-rules]]
    app = "Calculator"
    mode = "floating"

    [[window-rules]]
    app = "Slack"
    open-on-workspace = "Chat"
    """

    func testAddWorkspaceGoesAfterTheLastWorkspace() throws {
        let result = try patched(sample, [
            .addWorkspace(WorkspaceDefinition(name: "Browsers", icon: "globe", color: "#FF8800", display: .index(2))),
        ])
        XCTAssertEqual(result.config.workspaces.map(\.name), ["Code", "Chat", "Browsers"])
        XCTAssertEqual(
            result.config.workspaces[2],
            WorkspaceDefinition(name: "Browsers", icon: "globe", color: "#FF8800", display: .index(2))
        )
        let lines = result.text.components(separatedBy: "\n")
        let browsers = try XCTUnwrap(lines.firstIndex(of: "name = \"Browsers\""))
        let firstRule = try XCTUnwrap(lines.firstIndex(of: "[[window-rules]]"))
        XCTAssertLessThan(browsers, firstRule)
        XCTAssertTrue(result.text.contains("# the editor"))
        XCTAssertTrue(result.text.contains("# mine"))
    }

    func testAddWorkspaceWithoutAnyAppends() throws {
        let result = try patched("[layout]\ngaps = 8\n", [.addWorkspace(WorkspaceDefinition(name: "Code"))])
        XCTAssertEqual(result.text, "[layout]\ngaps = 8\n\n[[workspace]]\nname = \"Code\"\n")
    }

    func testUpdateWorkspaceKeepsCommentsAndRenames() throws {
        let result = try patched(sample, [
            .updateWorkspace(index: 1, WorkspaceDefinition(name: "Talk", display: .main)),
            .updateRule(index: 1, WindowRule(app: "Slack", openOnWorkspace: "Talk")),
        ])
        XCTAssertEqual(result.config.workspaces, [
            WorkspaceDefinition(name: "Code"), WorkspaceDefinition(name: "Talk", display: .main),
        ])
        XCTAssertEqual(result.config.rules[1].openOnWorkspace, "Talk")
        XCTAssertTrue(result.text.contains("# the editor"))
    }

    func testRemoveWorkspace() throws {
        let result = try patched(sample, [.removeWorkspace(index: 0)])
        XCTAssertEqual(result.config.workspaces.map(\.name), ["Chat"])
        XCTAssertFalse(result.text.contains("name = \"Code\""))
        XCTAssertTrue(result.text.contains("# mine"))
    }

    func testMoveWorkspaceReorders() throws {
        let result = try patched(sample, [.moveWorkspace(from: 1, to: 0)])
        XCTAssertEqual(result.config.workspaces.map(\.name), ["Chat", "Code"])
        // The comment travels with its block.
        let lines = result.text.components(separatedBy: "\n")
        let comment = try XCTUnwrap(lines.firstIndex(of: "# the editor"))
        XCTAssertEqual(lines[comment + 1], "name = \"Code\"")
    }

    func testMoveRuleReorders() throws {
        let result = try patched(sample, [.moveRule(from: 0, to: 1)])
        XCTAssertEqual(result.config.rules.map(\.app), ["Slack", "Calculator"])
        XCTAssertEqual(result.config.workspaces.map(\.name), ["Code", "Chat"])
    }

    func testRenderedRuleRoundTrips() throws {
        let rule = WindowRule(
            app: "Code", bundleID: "com.microsoft.VSCode", mode: .tiled, openOnWorkspace: "Code", follow: .never
        )
        let result = try patched(sample, [.addRule(rule)])
        XCTAssertEqual(result.config.rules.last, rule)
        XCTAssertTrue(result.text.contains("bundle-id = \"com.microsoft.VSCode\""))
        XCTAssertTrue(result.text.contains("follow = \"never\""))
    }

    func testDefaultFollowIsNotWritten() throws {
        let result = try patched(sample, [.addRule(WindowRule(app: "Mail", openOnWorkspace: "Chat"))])
        XCTAssertFalse(result.text.contains("follow ="))
    }

    func testOutOfRangeWorkspaceEditsFail() {
        for edit: ConfigEdit in [
            .updateWorkspace(index: 5, WorkspaceDefinition(name: "X")),
            .removeWorkspace(index: 5),
            .moveWorkspace(from: 0, to: 7),
            .moveRule(from: 4, to: 0),
        ] {
            guard case .failure = patchGioConfig(sample, edits: [edit]) else {
                return XCTFail("\(edit) should fail")
            }
        }
    }

    func testWorkspaceNamesWithQuotesAreRejected() {
        guard case .failure = patchGioConfig(sample, edits: [.addWorkspace(WorkspaceDefinition(name: "a\"b"))]) else {
            return XCTFail("quote must be rejected")
        }
    }

    func testTemplateDocumentsNamedWorkspacesCommentedOut() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("# [[workspace]]"))
        XCTAssertTrue(template.contains("# open-on-workspace = "))
        XCTAssertTrue(template.contains("# bundle-id = "))
        let (config, warnings) = try parsed(template)
        XCTAssertEqual(config.workspaces, [])
        XCTAssertEqual(warnings, [])
    }

    func testRuleFormKeepsTheNewFields() {
        let rule = WindowRule(
            app: "", bundleID: "com.microsoft.VSCode", mode: .floating, openOnWorkspace: "Code", follow: .always
        )
        let form = RuleForm(rule: rule)
        XCTAssertEqual(form.problems, [])
        XCTAssertEqual(form.rule, rule)
        XCTAssertEqual(RuleForm().problems, ["App name or title pattern is required."])
    }
}
