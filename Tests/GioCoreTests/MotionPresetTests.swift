import XCTest
@testable import GioCore

/// DD-06: the Fast / Animated motion presets shared by the first-run setup
/// and Settings → Animations. DD-10 (user 2026-11-04, "pon como recomendado
/// el fast"): Fast is the recommended preset and what Gio ships with.
final class MotionPresetTests: XCTestCase {
    func testAPresetReadsTheAnimationSwitch() {
        XCTAssertEqual(MotionPreset(animations: AnimationsSectionConfig()), .fast)
        XCTAssertEqual(MotionPreset(animations: AnimationsSectionConfig(enabled: true)), .animated)
    }

    func testEachPresetWritesItsSwitchAndRenderer() throws {
        let template = defaultConfigTemplate()
        let fast = try patchGioConfig(template, edits: motionPresetEdits(.fast)).get()
        XCTAssertFalse(fast.config.animations.enabled)
        XCTAssertEqual(fast.config.animations.renderer, .ax, "Fast moves the real windows, no Screen Recording")
        let animated = try patchGioConfig(template, edits: motionPresetEdits(.animated)).get()
        XCTAssertTrue(animated.config.animations.enabled)
        XCTAssertEqual(animated.config.animations.renderer, .snapshot)
        XCTAssertEqual(MotionPreset(animations: animated.config.animations), .animated)
    }

    func testGioShipsFast() throws {
        XCTAssertFalse(defaultGioConfig().animations.enabled)
        XCTAssertEqual(defaultGioConfig().animations.renderer, .ax)
        let (config, messages) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertEqual(messages, [])
        XCTAssertEqual(MotionPreset(animations: config.animations), .fast)
        XCTAssertEqual(config.animations.renderer, .ax)
    }

    func testEachPresetBringsItsRenderer() {
        XCTAssertEqual(MotionPreset.animated.renderer, .snapshot)
        XCTAssertEqual(MotionPreset.fast.renderer, .ax)
    }
}
