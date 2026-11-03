import XCTest
@testable import GioCore

/// DD-06: the Recommended / Fast motion presets shared by the first-run setup
/// and Settings → Animations.
final class MotionPresetTests: XCTestCase {
    func testAPresetReadsTheAnimationSwitch() {
        XCTAssertEqual(MotionPreset(animations: AnimationsSectionConfig()), .recommended)
        XCTAssertEqual(MotionPreset(animations: AnimationsSectionConfig(enabled: false)), .fast)
    }

    func testFastTurnsEveryAnimationOffAndRecommendedBackOn() throws {
        let template = defaultConfigTemplate()
        let fast = try patchGioConfig(template, edits: motionPresetEdits(.fast)).get()
        XCTAssertFalse(fast.config.animations.enabled)
        let recommended = try patchGioConfig(template, edits: motionPresetEdits(.recommended)).get()
        XCTAssertTrue(recommended.config.animations.enabled)
        XCTAssertEqual(MotionPreset(animations: fast.config.animations), .fast)
        XCTAssertTrue(defaultGioConfig().animations.enabled, "the default config ships Recommended")
    }

    func testTheTemplateStartsWithRecommended() throws {
        let (config, messages) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(MotionPreset(animations: config.animations), .recommended)
    }
}
