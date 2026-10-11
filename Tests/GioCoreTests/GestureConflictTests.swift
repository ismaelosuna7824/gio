import XCTest
@testable import GioCore

/// TG-04: Gio's swipes against the ones macOS performs itself, decided from
/// the trackpad and Dock preference values (missing keys are macOS's
/// defaults), with the System Settings path that changes each.
final class GestureConflictTests: XCTestCase {
    private let off: [String: Int] = [
        "TrackpadThreeFingerHorizSwipeGesture": 0, "TrackpadThreeFingerVertSwipeGesture": 0,
        "TrackpadFourFingerHorizSwipeGesture": 0, "TrackpadFourFingerVertSwipeGesture": 0,
        "TrackpadThreeFingerDrag": 0,
    ]

    private func detect(
        _ config: GesturesSectionConfig = GesturesSectionConfig(), trackpad: [String: Int], bluetooth: [String: Int] = [:],
        dock: [String: Int] = [:]
    ) -> [GestureConflict] {
        detectGestureConflicts(config, preferences: TrackpadSystemPreferences(trackpad: trackpad, bluetoothTrackpad: bluetooth, dock: dock))
    }

    func testMacOSDefaultsCollideWithGiosDefaults() {
        XCTAssertEqual(detect(trackpad: [:]), [
            GestureConflict(gesture: .scroll, fingers: 3, system: .fullScreenSwipe),
            GestureConflict(gesture: .workspaceSwipe, fingers: 3, system: .missionControl),
        ])
    }

    func testEverySystemSwipeOffMeansNoConflict() {
        XCTAssertEqual(detect(trackpad: off, bluetooth: off), [])
    }

    func testThreeFingerPageSwipeAndAppExpose() {
        var trackpad = off
        trackpad["TrackpadThreeFingerHorizSwipeGesture"] = 1
        trackpad["TrackpadThreeFingerVertSwipeGesture"] = 2
        let found = detect(trackpad: trackpad, bluetooth: off, dock: ["showMissionControlGestureEnabled": 0, "showAppExposeGestureEnabled": 1])
        XCTAssertEqual(found, [
            GestureConflict(gesture: .scroll, fingers: 3, system: .pageSwipe),
            GestureConflict(gesture: .workspaceSwipe, fingers: 3, system: .appExpose),
        ])
    }

    func testEitherTrackpadDomainEnablingASwipeCounts() {
        var bluetooth = off
        bluetooth["TrackpadFourFingerVertSwipeGesture"] = 2
        var config = GesturesSectionConfig()
        config.overview = true
        XCTAssertEqual(
            detect(config, trackpad: off, bluetooth: bluetooth),
            [GestureConflict(gesture: .overview, fingers: 4, system: .missionControl)]
        )
    }

    func testOverviewOnlyMeetsMissionControlNotAppExpose() {
        var trackpad = off
        trackpad["TrackpadFourFingerVertSwipeGesture"] = 2
        var config = GesturesSectionConfig(scroll: false, workspaceSwipe: false, overview: true)
        XCTAssertEqual(detect(config, trackpad: trackpad, dock: ["showMissionControlGestureEnabled": 0, "showAppExposeGestureEnabled": 1]), [])
        config.overview = false
        XCTAssertEqual(detect(config, trackpad: [:]), [], "gestures that are off collide with nothing")
    }

    func testThreeFingerDragCollidesWithEveryThreeFingerGesture() {
        var trackpad = off
        trackpad["TrackpadThreeFingerDrag"] = 1
        XCTAssertEqual(detect(trackpad: trackpad, bluetooth: off), [
            GestureConflict(gesture: .scroll, fingers: 3, system: .threeFingerDrag),
            GestureConflict(gesture: .workspaceSwipe, fingers: 3, system: .threeFingerDrag),
        ])
    }

    func testFiveFingersCollideWithNoSwipe() {
        let config = GesturesSectionConfig(scrollFingers: 5, workspaceFingers: 5)
        XCTAssertEqual(detect(config, trackpad: [:]), [])
    }

    func testMessagesNameTheSettingsPath() {
        let conflict = GestureConflict(gesture: .scroll, fingers: 3, system: .fullScreenSwipe)
        XCTAssertEqual(
            gestureConflictMessage(conflict),
            "Scroll (3 fingers) also triggers macOS Swipe between full-screen applications: change it in System Settings > Trackpad > More Gestures > Swipe between full-screen applications, or give Gio other fingers."
        )
        XCTAssertEqual(
            SystemTrackpadGesture.threeFingerDrag.settingsPath,
            "System Settings > Accessibility > Pointer Control > Trackpad Options > Dragging style"
        )
        XCTAssertEqual(SystemTrackpadGesture.appExpose.settingsPath, "System Settings > Trackpad > More Gestures > App Exposé")
    }

    func testLogGateSpeaksOnceThenOnChange() {
        var gate = GestureConflictLogGate()
        let conflicts = detect(trackpad: [:])
        XCTAssertEqual(gate.line(for: conflicts), "gestures conflict=scroll-3:full-screen-swipe,workspace-swipe-3:mission-control")
        XCTAssertNil(gate.line(for: conflicts))
        XCTAssertEqual(gate.line(for: []), "gestures conflict=none")
    }
}
