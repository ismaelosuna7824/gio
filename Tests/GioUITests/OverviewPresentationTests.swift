import GioCore
import XCTest
@testable import GioUI

/// DD-02: pure labels behind the Overview dashboard and sidebar header.
final class OverviewPresentationTests: XCTestCase {
    func testWindowStateBadges() {
        XCTAssertEqual(windowStateBadge(.tiled), StateBadge(kind: .neutral, label: "Tiled", symbol: "rectangle.split.3x1"))
        XCTAssertEqual(windowStateBadge(.floating(.dialog)).label, "Floating · Dialog")
        XCTAssertEqual(windowStateBadge(.floating(.notResizable)).label, "Floating · Fixed size")
        XCTAssertEqual(windowStateBadge(.floating(nil)).label, "Floating")
        XCTAssertEqual(windowStateBadge(.floating(.rule)).kind, .info)
        XCTAssertEqual(windowStateBadge(.minimized).label, "Minimized")
        XCTAssertEqual(windowStateBadge(.hidden).label, "Hidden")
        XCTAssertEqual(windowStateBadge(.fullscreen).label, "Fullscreen")
    }

    func testMotionSummary() {
        var config = AnimationsSectionConfig()
        config.renderer = .snapshot
        config.curve = .spring
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: true).value, "Snapshot")
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: true).detail, "Spring motion")
        XCTAssertEqual(motionSummary(config, screenRecording: false, windowServer: true).value, "Accessibility")
        XCTAssertEqual(
            motionSummary(config, screenRecording: false, windowServer: true).detail, "Snapshot needs Screen Recording"
        )
        config.renderer = .ax
        config.curve = .easeOut
        config.durationMilliseconds = 250
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: true).detail, "Ease-out · 250 ms")
        // PF-O: live needs SkyLight, not Screen Recording.
        config.renderer = .live
        XCTAssertEqual(motionSummary(config, screenRecording: false, windowServer: true).value, "Live")
        XCTAssertEqual(motionSummary(config, screenRecording: false, windowServer: true).detail, "Ease-out · 250 ms")
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: false).value, "Accessibility")
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: false).detail, "Live needs SkyLight")
        config.enabled = false
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: true).value, "Off")
        XCTAssertEqual(motionSummary(config, screenRecording: true, windowServer: true).detail, "Windows move instantly")
    }

    func testSessionStatus() {
        XCTAssertEqual(sessionStatus(nil), SessionStatus(kind: .neutral, label: "Starting"))
        XCTAssertEqual(sessionStatus(facts(ax: false)).label, "Needs access")
        XCTAssertEqual(sessionStatus(facts(ax: false)).kind, .warning)
        XCTAssertEqual(sessionStatus(facts(ax: true)), SessionStatus(kind: .ok, label: "Running"))
    }

    func testWorkspaceTotalsUseTheStripDisplay() {
        let stack = [
            WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: false),
            WorkspaceEntry(index: 2, windows: 3, columns: 2, isActive: true),
            WorkspaceEntry(index: 3, windows: 0, columns: 0, isActive: false),
        ]
        let value = workspaceTotals(facts(ax: true, displays: [
            DisplayFact(id: 1, workspace: 1, stack: [WorkspaceEntry(index: 1, windows: 1, columns: 1, isActive: true)]),
            DisplayFact(id: 2, workspace: 2, stack: stack),
        ], stripDisplay: 2, current: 2))
        XCTAssertEqual(value, "2 / 3")
        XCTAssertEqual(workspaceTotals(facts(ax: true, displays: [], stripDisplay: nil, current: 4)), "4")
    }

    private func facts(ax: Bool, displays: [DisplayFact] = [], stripDisplay: UInt32? = nil, current: Int = 1) -> SessionFacts {
        SessionFacts(
            configPath: "/c", configExists: true, configMessages: [], accessibilityGranted: ax,
            currentWorkspace: current, displays: displays, windows: [],
            strip: stripDisplay.map {
                WorkspaceStripFact(
                    displayID: $0, workspace: current, viewportWidth: 1, viewportHeight: 1,
                    viewportOffset: 0, contentWidth: 0, columns: [], focusedColumn: nil, focusedWindowID: nil
                )
            }
        )
    }
}
