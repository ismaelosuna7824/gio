import XCTest
@testable import GioCore

/// MO-04 config: `[animations] enabled / duration-ms`.
final class MotionConfigTests: XCTestCase {
    func testDefaultsAnimateFor200Ms() {
        let animations = defaultGioConfig().animations
        XCTAssertTrue(animations.enabled)
        XCTAssertEqual(animations.durationMilliseconds, 200)
        XCTAssertEqual(animations.duration, 0.2, accuracy: 1e-9)
        XCTAssertTrue(animations.isActive)
    }

    func testParsesEnabledAndDuration() throws {
        let (config, warnings) = try parseGioConfig("[animations]\nenabled = true\nduration-ms = 350\n").get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.animations.durationMilliseconds, 350)
    }

    func testDurationIsClampedWithAWarning() throws {
        let (high, highWarnings) = try parseGioConfig("[animations]\nduration-ms = 5000\n").get()
        XCTAssertEqual(high.animations.durationMilliseconds, 1000)
        XCTAssertEqual(highWarnings.count, 1)
        XCTAssertTrue(highWarnings[0].contains("animations.duration-ms"))
        let (low, lowWarnings) = try parseGioConfig("[animations]\nduration-ms = -40\n").get()
        XCTAssertEqual(low.animations.durationMilliseconds, 0)
        XCTAssertEqual(lowWarnings.count, 1)
    }

    func testZeroDurationOrDisabledMeansInstant() throws {
        let (zero, _) = try parseGioConfig("[animations]\nduration-ms = 0\n").get()
        XCTAssertFalse(zero.animations.isActive)
        let (off, _) = try parseGioConfig("[animations]\nenabled = false\nduration-ms = 200\n").get()
        XCTAssertFalse(off.animations.isActive)
    }

    func testNonNumericDurationIsAnError() {
        switch parseGioConfig("[animations]\nduration-ms = \"fast\"\n") {
        case .success:
            XCTFail("expected an error")
        case .failure(let errors):
            XCTAssertEqual(errors.messages, ["line 2: animations.duration-ms expects a number of milliseconds"])
        }
    }

    func testFractionalDurationRoundsToWholeMilliseconds() throws {
        let (config, _) = try parseGioConfig("[animations]\nduration-ms = 150.6\n").get()
        XCTAssertEqual(config.animations.durationMilliseconds, 151)
    }

    func testTemplateDocumentsTheSectionAndParsesClean() throws {
        let template = defaultConfigTemplate()
        XCTAssertTrue(template.contains("[animations]"))
        let (config, warnings) = try parseGioConfig(template).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.animations.durationMilliseconds, 200)
    }

    func testEchoGateSuppressesByTimeWithoutNeedingTheObservedFrame() {
        var gate = WriteEchoGate()
        let id = WindowID(pid: 1, elementID: 1)
        gate.recordApplied([id: CGRect(x: 0, y: 0, width: 10, height: 10)], at: 100)
        XCTAssertTrue(gate.isSuppressed(id, at: 100.2))
        XCTAssertFalse(gate.isSuppressed(id, at: 101))
        XCTAssertFalse(gate.isSuppressed(WindowID(pid: 2, elementID: 1), at: 100.1))
    }
}
