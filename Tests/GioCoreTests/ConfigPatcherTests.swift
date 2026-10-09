import XCTest
@testable import GioCore

/// DA-04: text-level config edits. Unrelated lines and comments survive,
/// missing sections/keys are created, and a patch never yields text the
/// parser rejects.
final class ConfigPatcherTests: XCTestCase {
    private let sample = """
    # my config
    [layout]
    gaps = 8   # breathing room
    padding = 8

    # animations
    [animations]
    enabled = true

    [[window-rules]]
    # calc floats
    app = "Calculator"
    mode = "floating"

    [[window-rules]]
    app = "Notes"
    workspace = 2

    [keybindings]
    "Alt+H" = "focus-left"
    """

    private func patched(_ text: String, _ edits: [ConfigEdit]) throws -> PatchedConfig {
        switch patchGioConfig(text, edits: edits) {
        case .success(let value): return value
        case .failure(let errors):
            XCTFail("patch failed: \(errors.messages)")
            throw errors
        }
    }

    func testSetExistingKeyKeepsEverythingElseAndInlineComment() throws {
        let result = try patched(sample, [.set(table: "layout", key: "gaps", value: .number(12))])
        XCTAssertTrue(result.text.contains("gaps = 12  # breathing room"))
        XCTAssertEqual(result.config.layout.gaps, 12)
        var original = sample.components(separatedBy: "\n")
        var after = result.text.components(separatedBy: "\n")
        original.removeAll { $0.hasPrefix("gaps") }
        after.removeAll { $0.hasPrefix("gaps") }
        while after.last == "" { after.removeLast() }
        XCTAssertEqual(after, original)
    }

    func testMissingKeyIsInsertedInsideExistingSection() throws {
        let result = try patched(sample, [.set(table: "animations", key: "duration-ms", value: .int(250))])
        let lines = result.text.components(separatedBy: "\n")
        let enabled = try XCTUnwrap(lines.firstIndex(of: "enabled = true"))
        XCTAssertEqual(lines[enabled + 1], "duration-ms = 250")
        XCTAssertEqual(result.config.animations.durationMilliseconds, 250)
    }

    func testMissingSectionIsAppendedAtTheEnd() throws {
        let result = try patched(sample, [.set(table: "behavior", key: "focus-follows-mouse", value: .bool(true))])
        XCTAssertTrue(result.text.hasSuffix("[behavior]\nfocus-follows-mouse = true\n"))
        XCTAssertTrue(result.config.behavior.focusFollowsMouse)
        XCTAssertTrue(result.text.hasPrefix("# my config\n[layout]"))
    }

    func testEmptyTextGetsSectionAndKey() throws {
        let result = try patched("", [.set(table: "layout", key: "padding", value: .int(4))])
        XCTAssertEqual(result.text, "[layout]\npadding = 4\n")
    }

    func testPresetListRoundTrips() throws {
        let result = try patched(sample, [
            .set(table: "layout", key: "preset-column-widths", value: .numbers([0.33, 0.5, 0.67, 800]))
        ])
        XCTAssertTrue(result.text.contains("preset-column-widths = [0.33, 0.5, 0.67, 800]"))
        XCTAssertEqual(
            result.config.layout.presetColumnWidths,
            [.proportion(0.33), .proportion(0.5), .proportion(0.67), .points(800)]
        )
    }

    func testQuotedTableKeyIsUpdatedNotDuplicated() throws {
        let result = try patched(sample, [.set(table: "keybindings", key: "Alt+H", value: .string("focus-right"))])
        XCTAssertEqual(result.text.components(separatedBy: "Alt+H").count, 2)
        XCTAssertTrue(result.text.contains("Alt+H = \"focus-right\"") || result.text.contains("\"Alt+H\" = \"focus-right\""))
    }

    func testRemoveKeyDropsOnlyThatLine() throws {
        let result = try patched(sample, [.remove(table: "layout", key: "padding")])
        XCTAssertFalse(result.text.contains("padding"))
        XCTAssertTrue(result.text.contains("gaps = 8"))
        XCTAssertEqual(result.config.layout.padding, 8)
    }

    func testAddRuleAppendsBlock() throws {
        let result = try patched(sample, [.addRule(WindowRule(app: "Finder", mode: .floating, workspace: 3))])
        XCTAssertTrue(result.text.hasSuffix(
            "[[window-rules]]\napp = \"Finder\"\nmode = \"floating\"\nworkspace = 3\n"
        ))
        XCTAssertEqual(result.config.rules.count, 3)
        XCTAssertEqual(result.config.rules[2], WindowRule(app: "Finder", mode: .floating, workspace: 3))
    }

    func testUpdateRuleReplacesOnlyThatBlock() throws {
        let result = try patched(sample, [.updateRule(index: 1, WindowRule(app: "Notes", mode: .tiled, workspace: 5))])
        XCTAssertEqual(result.config.rules[0], WindowRule(app: "Calculator", mode: .floating))
        XCTAssertEqual(result.config.rules[1], WindowRule(app: "Notes", mode: .tiled, workspace: 5))
        XCTAssertTrue(result.text.contains("# calc floats"))
        XCTAssertTrue(result.text.contains("[keybindings]\n\"Alt+H\" = \"focus-left\""))
    }

    func testRemoveRuleKeepsNeighboursAndComments() throws {
        let result = try patched(sample, [.removeRule(index: 0)])
        XCTAssertEqual(result.config.rules, [WindowRule(app: "Notes", workspace: 2)])
        XCTAssertTrue(result.text.contains("# my config"))
        XCTAssertTrue(result.text.contains("# animations"))
        XCTAssertFalse(result.text.contains("Calculator"))
        XCTAssertFalse(result.text.contains("\n\n\n"))
    }

    func testRuleIndexOutOfRangeFails() {
        guard case .failure(let errors) = patchGioConfig(sample, edits: [.removeRule(index: 9)]) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(errors.messages[0].contains("rule"))
    }

    func testPatchIsIdempotent() throws {
        let edit = ConfigEdit.set(table: "layout", key: "gaps", value: .int(20))
        let once = try patched(sample, [edit])
        let twice = try patched(once.text, [edit])
        XCTAssertEqual(once.text, twice.text)
    }

    func testInvalidResultIsRejectedWithParserMessages() {
        guard case .failure(let errors) = patchGioConfig(
            sample, edits: [.set(table: "layout", key: "gaps", value: .number(-3))]
        ) else {
            return XCTFail("negative gaps must be rejected")
        }
        XCTAssertTrue(errors.messages.joined().contains("layout.gaps"))
    }

    func testAlreadyBrokenFileIsNotPatched() {
        guard case .failure(let errors) = patchGioConfig(
            "[layout]\ngaps = ???\n", edits: [.set(table: "layout", key: "padding", value: .int(1))]
        ) else {
            return XCTFail("broken input must fail")
        }
        XCTAssertFalse(errors.messages.isEmpty)
    }

    func testStringsThatCannotBeRepresentedAreRejected() {
        guard case .failure = patchGioConfig(
            sample, edits: [.addRule(WindowRule(app: "Bad\"App"))]
        ) else {
            return XCTFail("a quote in a string cannot be written")
        }
    }

    func testWarningsPassThrough() throws {
        let result = try patched("[layout]\nfoo = 1\n", [.set(table: "layout", key: "gaps", value: .int(2))])
        XCTAssertTrue(result.warnings.joined().contains("foo"))
    }
}

final class ConfigWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appendingPathComponent("sub/config.toml").path }

    func testMissingFileIsCreatedFromTemplateThenPatched() throws {
        let outcome = applyConfigEdits(
            [.set(table: "layout", key: "gaps", value: .int(14))], toFileAt: path
        )
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(value.config.layout.gaps, 14)
        let onDisk = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(onDisk, value.text)
        XCTAssertTrue(onDisk.contains("# Gio config"))
    }

    func testInvalidPatchLeavesFileUntouched() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try "[layout]\ngaps = 3\n".write(toFile: path, atomically: true, encoding: .utf8)
        let outcome = applyConfigEdits(
            [.set(table: "layout", key: "gaps", value: .int(-1))], toFileAt: path
        )
        guard case .failure(let errors) = outcome else { return XCTFail("expected failure") }
        XCTAssertFalse(errors.messages.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[layout]\ngaps = 3\n")
    }

    func testNoTemporaryFilesRemainAfterWrite() throws {
        _ = applyConfigEdits([.set(table: "layout", key: "gaps", value: .int(9))], toFileAt: path)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: (path as NSString).deletingLastPathComponent
        )
        XCTAssertEqual(names, ["config.toml"])
    }
}

final class SettingsFormTests: XCTestCase {
    func testLayoutFormMirrorsConfigAndBuildsEdits() throws {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        XCTAssertEqual(form.gaps, 8)
        XCTAssertEqual(form.widthKind, .fraction)
        XCTAssertEqual(form.widthValue, 0.5)
        form.gaps = 12
        form.widthKind = .points
        form.widthValue = 900
        form.presetsText = "0.33, 0.5, 700"
        XCTAssertEqual(form.presetHeightsText, "0.33333, 0.5, 0.66667")
        form.presetHeightsText = "0.25, 500"
        XCTAssertTrue(form.problems.isEmpty)
        let result = try {
            switch patchGioConfig("", edits: form.edits) {
            case .success(let value): return value
            case .failure(let e): throw e
            }
        }()
        XCTAssertEqual(result.config.layout.gaps, 12)
        XCTAssertEqual(result.config.layout.defaultColumnWidthPoints, 900)
        XCTAssertEqual(
            result.config.layout.presetColumnWidths,
            [.proportion(0.33), .proportion(0.5), .points(700)]
        )
        XCTAssertEqual(result.config.layout.presetWindowHeights, [.proportion(0.25), .points(500)])
    }

    func testLayoutFormReportsProblems() {
        var form = LayoutSettingsForm(config: LayoutSectionConfig())
        form.gaps = -1
        form.widthKind = .fraction
        form.widthValue = 1.5
        form.presetsText = "abc"
        XCTAssertEqual(form.problems.count, 3)
        form.presetHeightsText = "0.5, -2"
        XCTAssertTrue(form.problems.contains("Preset heights must be a comma-separated list of positive numbers."))
        form.widthKind = .points
        form.widthValue = 0.5
        XCTAssertTrue(form.problems.contains { $0.contains("points") })
    }

    func testPresetTextParsing() {
        XCTAssertEqual(parsePresetList("0.5,  1, 640"), [0.5, 1, 640])
        XCTAssertNil(parsePresetList(""))
        XCTAssertNil(parsePresetList("0.5, x"))
        XCTAssertNil(parsePresetList("0.5, -2"))
    }

    func testAnimationAndBehaviorEdits() {
        XCTAssertEqual(animationEdits(enabled: false, durationMilliseconds: 350), [
            .set(table: "animations", key: "enabled", value: .bool(false)),
            .set(table: "animations", key: "duration-ms", value: .int(350)),
        ])
        XCTAssertEqual(behaviorEdits(focusFollowsMouse: true, mouseFollowsFocus: false), [
            .set(table: "behavior", key: "focus-follows-mouse", value: .bool(true)),
            .set(table: "behavior", key: "mouse-follows-focus", value: .bool(false)),
        ])
    }

    func testRuleFormValidation() {
        var form = RuleForm()
        XCTAssertFalse(form.problems.isEmpty)
        form.app = "  Finder "
        form.mode = .floating
        form.workspace = 3
        XCTAssertTrue(form.problems.isEmpty)
        XCTAssertEqual(form.rule, WindowRule(app: "Finder", mode: .floating, workspace: 3))
        form.workspace = 12
        XCTAssertFalse(form.problems.isEmpty)
        XCTAssertEqual(RuleForm(rule: WindowRule(app: "A", mode: nil, workspace: nil)).mode, nil)
    }
}
