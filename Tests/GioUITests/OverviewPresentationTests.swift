import GioCore
import XCTest
@testable import GioUI

/// DD-02: pure labels behind the Overview dashboard and sidebar header.
final class OverviewPresentationTests: XCTestCase {
    func testWindowStateBadges() {
        XCTAssertEqual(windowStateBadge(.tiled), StateBadge(kind: .neutral, label: "Tiled", symbol: "rectangle.split.3x1"))
        XCTAssertEqual(windowStateBadge(.floating(.dialog)).label, "Floating · Dialog")
        XCTAssertEqual(windowStateBadge(.floating(.notResizable)).label, "Floating · Fixed size")
        XCTAssertEqual(windowStateBadge(.floating(.appControlled)).label, "Floating · App-controlled")
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
        XCTAssertEqual(motionSummary(config, screenRecording: true).value, "Snapshot")
        XCTAssertEqual(motionSummary(config, screenRecording: true).detail, "Spring motion")
        XCTAssertEqual(motionSummary(config, screenRecording: false).value, "Accessibility")
        XCTAssertEqual(motionSummary(config, screenRecording: false).detail, "Snapshot needs Screen Recording")
        config.renderer = .ax
        config.curve = .easeOut
        config.durationMilliseconds = 250
        XCTAssertEqual(motionSummary(config, screenRecording: true).detail, "Ease-out · 250 ms")
        config.enabled = false
        XCTAssertEqual(motionSummary(config, screenRecording: true).value, "Off")
        XCTAssertEqual(motionSummary(config, screenRecording: true).detail, "Windows move instantly")
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
