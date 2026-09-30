import XCTest
@testable import GioCore

/// SM-01: `[animations] renderer` and the pure choice between the snapshot
/// (ScreenCaptureKit) renderer and the Accessibility motion.
final class RendererSettingTests: XCTestCase {
    func testDefaultIsAxAndBothValuesParse() throws {
        XCTAssertEqual(defaultGioConfig().animations.renderer, .ax)
        for kind in ["snapshot", "ax"] {
            let (config, warnings) = try parseGioConfig("[animations]\nrenderer = \"\(kind)\"\n").get()
            XCTAssertTrue(warnings.isEmpty)
            XCTAssertEqual(config.animations.renderer.rawValue, kind)
        }
    }

    func testUnknownRendererWarnsAndKeepsDefault() throws {
        let (config, warnings) = try parseGioConfig("[animations]\nrenderer = \"gpu\"\n").get()
        XCTAssertEqual(config.animations.renderer, .ax)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("animations.renderer"))
    }

    func testNonStringRendererIsAnError() {
        XCTAssertThrowsError(try parseGioConfig("[animations]\nrenderer = 3\n").get())
    }

    func testTemplateDeclaresRenderer() throws {
        XCTAssertTrue(defaultConfigTemplate().contains("renderer = \"ax\""))
        let (config, warnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.animations.renderer, .ax)
    }

    func testAnimationEditsCarryRendererWhenGiven() {
        XCTAssertEqual(
            animationEdits(enabled: true, durationMilliseconds: 200, renderer: .ax).last,
            .set(table: "animations", key: "renderer", value: .string("ax"))
        )
        XCTAssertFalse(
            animationEdits(enabled: true, durationMilliseconds: 200).contains {
                if case .set(_, "renderer", _) = $0 { return true } else { return false }
            }
        )
    }

    func testSnapshotOnlyWhenConfiguredAndGranted() {
        var animations = AnimationsSectionConfig()
        animations.renderer = .snapshot
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true), .snapshot)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: false), .ax)
        animations.renderer = .ax
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true), .ax)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: false), .ax)
    }

    func testReasonNamesWhyTheRendererWasChosen() {
        var animations = AnimationsSectionConfig()
        animations.renderer = .snapshot
        XCTAssertEqual(rendererReason(config: animations, permission: true), "configured")
        XCTAssertEqual(rendererReason(config: animations, permission: false), "screen-recording-missing")
        animations.renderer = .ax
        XCTAssertEqual(rendererReason(config: animations, permission: true), "config-ax")
        XCTAssertEqual(rendererReason(config: animations, permission: false), "config-ax")
    }

    func testLogGateEmitsOnlyOnChange() {
        var gate = RendererLogGate()
        var animations = AnimationsSectionConfig()
        animations.renderer = .snapshot
        XCTAssertEqual(
            gate.line(config: animations, permission: false),
            "renderer effective=ax reason=screen-recording-missing"
        )
        XCTAssertNil(gate.line(config: animations, permission: false))
        XCTAssertEqual(
            gate.line(config: animations, permission: true), "renderer effective=snapshot reason=configured"
        )
        XCTAssertNil(gate.line(config: animations, permission: true))
        animations.renderer = .ax
        XCTAssertEqual(gate.line(config: animations, permission: true), "renderer effective=ax reason=config-ax")
    }

    func testOverviewAndDiagnosticsReportScreenRecording() {
        func facts(_ granted: Bool) -> SessionFacts {
            SessionFacts(
                configPath: "/c", configExists: true, configMessages: [],
                accessibilityGranted: true, currentWorkspace: 1, displays: [], windows: [],
                screenRecordingGranted: granted
            )
        }
        XCTAssertTrue(makeOverview(facts(true)).screenRecordingGranted)
        XCTAssertFalse(makeOverview(facts(false)).screenRecordingGranted)
        func row(_ granted: Bool) -> DiagnosticRow? {
            makeDiagnostics(
                facts: facts(granted), version: "1", build: nil, socketPath: "s", socketExists: true,
                logPath: "l"
            ).first { $0.title == "Screen Recording" }
        }
        XCTAssertEqual(row(true)?.value, "Granted")
        XCTAssertEqual(row(true)?.status, .ok)
        XCTAssertEqual(row(false)?.status, .warning)
        XCTAssertTrue(row(false)?.value.hasPrefix("Missing") ?? false)
    }
}
