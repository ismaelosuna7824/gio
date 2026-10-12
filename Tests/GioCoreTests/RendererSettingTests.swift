import XCTest
@testable import GioCore

/// SM-01: `[animations] renderer` and the pure choice between the snapshot
/// (ScreenCaptureKit) renderer and the Accessibility motion. PF-O: the live
/// renderer (real windows through SkyLight) is the default.
final class RendererSettingTests: XCTestCase {
    func testDefaultIsLiveAndEveryValueParses() throws {
        XCTAssertEqual(defaultGioConfig().animations.renderer, .live)
        XCTAssertEqual(AnimationsSectionConfig().renderer, .live)
        for kind in ["live", "snapshot", "ax"] {
            let (config, warnings) = try parseGioConfig("[animations]\nrenderer = \"\(kind)\"\n").get()
            XCTAssertTrue(warnings.isEmpty)
            XCTAssertEqual(config.animations.renderer.rawValue, kind)
        }
    }

    func testUnknownRendererWarnsAndKeepsDefault() throws {
        let (config, warnings) = try parseGioConfig("[animations]\nrenderer = \"gpu\"\n").get()
        XCTAssertEqual(config.animations.renderer, .live)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("animations.renderer"))
        XCTAssertTrue(warnings[0].contains("\"live\""))
    }

    func testNonStringRendererIsAnError() {
        XCTAssertThrowsError(try parseGioConfig("[animations]\nrenderer = 3\n").get())
    }

    func testTemplateDeclaresRenderer() throws {
        let (config, warnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.animations.renderer, .live)
        XCTAssertTrue(defaultConfigTemplate().contains("renderer = \"live\""))
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
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true, windowServer: true), .snapshot)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: false, windowServer: true), .ax)
        animations.renderer = .ax
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true, windowServer: true), .ax)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: false, windowServer: true), .ax)
    }

    /// PF-O: live needs the SkyLight transport (config on, symbols, probe
    /// not failed); without it the motion is the AX renderer's. Screen
    /// Recording plays no part.
    func testLiveOnlyWithTheWindowServerTransport() {
        var animations = AnimationsSectionConfig()
        animations.renderer = .live
        XCTAssertEqual(effectiveRenderer(config: animations, permission: false, windowServer: true), .live)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true, windowServer: true), .live)
        XCTAssertEqual(effectiveRenderer(config: animations, permission: true, windowServer: false), .ax)
    }

    func testReasonNamesWhyTheRendererWasChosen() {
        var animations = AnimationsSectionConfig()
        animations.renderer = .snapshot
        XCTAssertEqual(rendererReason(config: animations, permission: true, windowServer: false), "configured")
        XCTAssertEqual(rendererReason(config: animations, permission: false, windowServer: true), "screen-recording-missing")
        animations.renderer = .ax
        XCTAssertEqual(rendererReason(config: animations, permission: true, windowServer: true), "config-ax")
        XCTAssertEqual(rendererReason(config: animations, permission: false, windowServer: false), "config-ax")
        animations.renderer = .live
        XCTAssertEqual(rendererReason(config: animations, permission: false, windowServer: true), "configured")
        XCTAssertEqual(rendererReason(config: animations, permission: true, windowServer: false), "skylight-unavailable")
    }

    func testLogGateEmitsOnlyOnChange() {
        var gate = RendererLogGate()
        var animations = AnimationsSectionConfig()
        animations.renderer = .snapshot
        XCTAssertEqual(
            gate.line(config: animations, permission: false, windowServer: true),
            "renderer effective=ax reason=screen-recording-missing"
        )
        XCTAssertNil(gate.line(config: animations, permission: false, windowServer: true))
        XCTAssertEqual(
            gate.line(config: animations, permission: true, windowServer: true), "renderer effective=snapshot reason=configured"
        )
        XCTAssertNil(gate.line(config: animations, permission: true, windowServer: true))
        animations.renderer = .ax
        XCTAssertEqual(
            gate.line(config: animations, permission: true, windowServer: true), "renderer effective=ax reason=config-ax"
        )
        animations.renderer = .live
        XCTAssertEqual(
            gate.line(config: animations, permission: false, windowServer: true), "renderer effective=live reason=configured"
        )
        // The probe refuted SkyLight mid-session: the fallback is logged once.
        XCTAssertEqual(
            gate.line(config: animations, permission: false, windowServer: false),
            "renderer effective=ax reason=skylight-unavailable"
        )
        XCTAssertNil(gate.line(config: animations, permission: false, windowServer: false))
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
