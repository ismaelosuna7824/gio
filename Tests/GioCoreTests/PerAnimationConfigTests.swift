import CoreGraphics
import XCTest
@testable import GioCore

final class PerAnimationConfigTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (GioConfig, [String]) {
        switch parseGioConfig(text) {
        case .success(let result):
            return result
        case .failure(let errors):
            XCTFail("\(errors.messages)", file: file, line: line)
            return (defaultGioConfig(), [])
        }
    }

    // MARK: Model

    func testNiriNames() {
        XCTAssertEqual(AnimationKind.allCases.map(\.rawValue), [
            "horizontal-view-movement", "window-movement", "workspace-switch",
            "window-open", "window-close", "window-resize",
        ])
        XCTAssertEqual(AnimationKind.windowOpen.tableName, "animations.window-open")
    }

    func testEveryKindInheritsTheGlobalSettings() {
        var config = AnimationsSectionConfig()
        config.curve = .easeOut
        config.durationMilliseconds = 320
        config.springStiffness = 500
        for kind in AnimationKind.allCases {
            let resolved = config.resolved(kind)
            XCTAssertEqual(resolved.enabled, kind != .windowResize, "\(kind)")
            XCTAssertEqual(resolved.curve, .easeOut)
            XCTAssertEqual(resolved.durationMilliseconds, 320)
            XCTAssertEqual(resolved.spring, config.spring)
        }
    }

    /// Live 2026-10-15: animating a resize with window images always shows
    /// the content jump from one layout to the other (Alt+F on Postman, three
    /// recordings); the user found an instant resize better and chose it as
    /// the default. `[animations.window-resize] enabled = true` brings the
    /// animation back.
    func testResizesAreInstantByDefaultAndTheirTableTurnsThemOn() {
        let defaults = AnimationsSectionConfig()
        XCTAssertFalse(defaults.resolved(.windowResize).isActive)
        XCTAssertTrue(defaults.resolved(.windowMovement).isActive)
        let (config, warnings) = parse("""
        [animations.window-resize]
        enabled = true
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertTrue(config.animations.resolved(.windowResize).isActive)
        var off = AnimationsSectionConfig()
        off.enabled = false
        off.overrides[.windowResize] = AnimationOverride(enabled: true)
        XCTAssertFalse(off.resolved(.windowResize).isActive, "the global switch still turns every animation off")
    }

    func testOverridesReplaceOnlyWhatTheySet() {
        var config = AnimationsSectionConfig()
        config.overrides[.windowMovement] = AnimationOverride(curve: .easeOut, durationMilliseconds: 90)
        config.overrides[.workspaceSwitch] = AnimationOverride(springDampingRatio: 0.7)
        config.overrides[.windowClose] = AnimationOverride(enabled: false)

        let movement = config.resolved(.windowMovement)
        XCTAssertEqual(movement.curve, .easeOut)
        XCTAssertEqual(movement.durationMilliseconds, 90)
        XCTAssertEqual(movement.spring.stiffness, config.springStiffness)
        XCTAssertEqual(config.resolved(.workspaceSwitch).spring.dampingRatio, 0.7)
        XCTAssertEqual(config.resolved(.workspaceSwitch).curve, .spring)
        XCTAssertFalse(config.resolved(.windowClose).isActive)
        XCTAssertTrue(config.resolved(.windowOpen).isActive)
    }

    func testGlobalOffTurnsEveryKindOff() {
        var config = AnimationsSectionConfig(enabled: false)
        config.overrides[.windowOpen] = AnimationOverride(enabled: true)
        XCTAssertFalse(config.resolved(.windowOpen).isActive)
        config = AnimationsSectionConfig()
        config.overrides[.windowResize] = AnimationOverride(durationMilliseconds: 0)
        XCTAssertFalse(config.resolved(.windowResize).isActive, "0 ms is instant, like the global value")
    }

    // MARK: Parser

    func testDottedTablesParseEveryKind() {
        let (config, warnings) = parse("""
        [animations]
        curve = "spring"

        [animations.horizontal-view-movement]
        spring-stiffness = 1200

        [animations.window-movement]
        curve = "ease-out"
        duration-ms = 150

        [animations.workspace-switch]
        enabled = false

        [animations.window-open]
        spring-damping-ratio = 0.8
        offset = 40

        [animations.window-close]
        ghost = true

        [animations.window-resize]
        duration-ms = 0
        """)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.animations.overrides[.horizontalViewMovement], AnimationOverride(springStiffness: 1200))
        XCTAssertEqual(
            config.animations.overrides[.windowMovement], AnimationOverride(curve: .easeOut, durationMilliseconds: 150)
        )
        XCTAssertEqual(config.animations.overrides[.workspaceSwitch], AnimationOverride(enabled: false))
        XCTAssertEqual(config.animations.overrides[.windowOpen], AnimationOverride(springDampingRatio: 0.8))
        XCTAssertEqual(config.animations.openOffset, 40)
        XCTAssertTrue(config.animations.closeGhost)
        XCTAssertNil(config.animations.overrides[.windowClose])
        XCTAssertEqual(config.animations.overrides[.windowResize], AnimationOverride(durationMilliseconds: 0))
    }

    func testDottedTablesValidateLikeTheGlobalTable() {
        let (config, warnings) = parse("""
        [animations.window-movement]
        spring-stiffness = 99999
        duration-ms = 5000
        curve = "bounce"
        wobble = 3

        [animations.window-open]
        offset = 900
        ghost = true

        [animations.sparkle]
        enabled = true
        """)
        XCTAssertEqual(config.animations.overrides[.windowMovement]?.springStiffness, SpringParameters.stiffnessRange.upperBound)
        XCTAssertEqual(config.animations.overrides[.windowMovement]?.durationMilliseconds, 1000)
        XCTAssertNil(config.animations.overrides[.windowMovement]?.curve)
        XCTAssertEqual(config.animations.openOffset, AnimationsSectionConfig.openOffsetRange.upperBound)
        XCTAssertFalse(config.animations.closeGhost, "ghost belongs to window-close only")
        XCTAssertEqual(warnings.count, 7, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("animations.window-movement.spring-stiffness clamped") })
        XCTAssertTrue(warnings.contains { $0.contains("unknown animations.window-movement key 'wobble'") })
        XCTAssertTrue(warnings.contains { $0.contains("unknown animations.window-open key 'ghost'") })
        XCTAssertTrue(warnings.contains { $0.contains("unknown table [animations.sparkle]") })
    }

    func testDottedTableTypeErrorsAreErrors() {
        guard case .failure(let errors) = parseGioConfig("""
        [animations.window-close]
        ghost = "yes"
        [animations.window-resize]
        enabled = 1
        """) else {
            return XCTFail("expected errors")
        }
        XCTAssertEqual(errors.messages.count, 2)
        XCTAssertTrue(errors.messages[0].contains("animations.window-close.ghost expects true or false"))
    }

    func testTemplateParsesAndDocumentsEveryKind() throws {
        let text = defaultConfigTemplate()
        let (config, warnings) = parse(text)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.animations, AnimationsSectionConfig())
        for kind in AnimationKind.allCases {
            XCTAssertTrue(text.contains("[\(kind.tableName)]"), kind.rawValue)
        }
    }

    // MARK: Patcher

    func testSettingAKindKeyCreatesItsTableAfterTheAnimationsFamily() throws {
        let text = """
        [animations]
        enabled = true

        [focus]
        indicator = "dim"
        """
        let patched = try patchGioConfig(text, edits: [
            .set(table: "animations.window-open", key: "offset", value: .number(30)),
            .set(table: "animations.window-close", key: "ghost", value: .bool(true)),
        ]).get()
        XCTAssertEqual(patched.text, """
        [animations]
        enabled = true

        [animations.window-open]
        offset = 30

        [animations.window-close]
        ghost = true

        [focus]
        indicator = "dim"

        """)
        XCTAssertEqual(patched.config.animations.openOffset, 30)
    }

    func testRemovingTheLastKeyDropsTheEmptyKindTable() throws {
        let text = """
        [animations]
        enabled = true

        [animations.window-movement]
        curve = "ease-out"

        [focus]
        indicator = "dim"
        """
        let patched = try patchGioConfig(text, edits: [
            .remove(table: "animations.window-movement", key: "curve"),
        ]).get()
        XCTAssertEqual(patched.text, """
        [animations]
        enabled = true

        [focus]
        indicator = "dim"

        """)
    }

    func testOverrideEditsSetWhatIsCustomAndRemoveTheRest() {
        let edits = animationOverrideEdits(
            .windowMovement, override: AnimationOverride(enabled: false, curve: .easeOut, durationMilliseconds: 120)
        )
        let table = "animations.window-movement"
        XCTAssertEqual(edits, [
            .set(table: table, key: "enabled", value: .bool(false)),
            .set(table: table, key: "curve", value: .string("ease-out")),
            .remove(table: table, key: "spring-damping-ratio"),
            .remove(table: table, key: "spring-stiffness"),
            .set(table: table, key: "duration-ms", value: .int(120)),
        ])
    }

    // MARK: Classification

    func testActionsMapToTheirTriggeringAnimation() {
        XCTAssertEqual(motionCause(for: .focusRight).kind, .horizontalViewMovement)
        XCTAssertEqual(motionCause(for: .centerColumn).kind, .horizontalViewMovement)
        XCTAssertEqual(motionCause(for: .moveColumnLeft).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .consumeOrExpelRight).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .workspace(2)).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .moveWindowToWorkspaceDown).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .maximizeColumn).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .fullscreen).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .growColumnWidth).kind, .windowResize)
        // MM-02: windows crossing displays move; focus and workspaces switch.
        XCTAssertEqual(motionCause(for: .moveColumnToMonitor(.left)).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .moveWindowToMonitor(.right)).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .focusMonitor(.up)).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .moveWorkspaceToMonitor(.down)).kind, .workspaceSwitch)
        // NC-08..NC-11.
        XCTAssertEqual(motionCause(for: .focusColumnFirst).kind, .horizontalViewMovement)
        XCTAssertEqual(motionCause(for: .focusColumnLast).kind, .horizontalViewMovement)
        XCTAssertEqual(motionCause(for: .moveColumnToFirst).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .swapWindowRight).kind, .windowMovement)
        XCTAssertEqual(motionCause(for: .growWindowHeight).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .resetWindowHeight).kind, .windowResize)
        XCTAssertEqual(motionCause(for: .moveColumnToWorkspace(2)).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .moveColumnToWorkspaceDown).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .focusWorkspacePrevious).kind, .workspaceSwitch)
        XCTAssertEqual(motionCause(for: .moveWorkspaceUp).kind, .workspaceSwitch)
        XCTAssertEqual(MotionCause.windowOpen.kind, .windowOpen)
        XCTAssertEqual(MotionCause.windowClose.kind, .windowClose)
        XCTAssertEqual(MotionCause.passive.kind, .windowMovement)
    }

    func testCoalescedCausesKeepTheDominantOne() {
        var latch = MotionCauseLatch()
        XCTAssertEqual(latch.take(), .passive)
        latch.note(.windowOpen)
        latch.note(.viewScroll)
        latch.note(.windowClose)
        XCTAssertEqual(latch.take(), .viewScroll, "a user action outranks window events")
        XCTAssertEqual(latch.take(), .passive, "taking resets")
        latch.note(.windowResize)
        latch.note(.windowMovement)
        XCTAssertEqual(latch.take(), .windowResize)
        latch.note(.windowMovement)
        latch.note(.workspaceSwitch)
        XCTAssertEqual(latch.take(), .workspaceSwitch)
    }

    func testEntriesAndSwitchesKeepTheirOwnKindWhateverTheCause() {
        let a = WindowID(pid: 1, elementID: 1)
        let b = WindowID(pid: 2, elementID: 2)
        let c = WindowID(pid: 3, elementID: 3)
        let kinds = classifyAnimationKinds([a, b, c], cause: .viewScroll, opening: [a], switching: [b])
        XCTAssertEqual(kinds, [a: .windowOpen, b: .workspaceSwitch, c: .horizontalViewMovement])
    }
}
