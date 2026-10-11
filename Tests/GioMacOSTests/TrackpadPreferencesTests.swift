import Foundation
import XCTest
@testable import GioCore
@testable import GioMacOS

/// TG-04: macOS's trackpad and Dock preference values become plain
/// integers for the conflict decision; anything that is not a number or a
/// boolean is left out (macOS's default applies).
final class TrackpadPreferencesTests: XCTestCase {
    func testNumbersAndBooleansBecomeIntegersAndTheRestIsMissing() {
        let stored: [String: Any] = [
            "TrackpadThreeFingerHorizSwipeGesture": NSNumber(value: 2),
            "TrackpadThreeFingerDrag": true,
            "showMissionControlGestureEnabled": false,
            "TrackpadFourFingerVertSwipeGesture": "two",
        ]
        let values = preferenceValues(
            TrackpadSystemPreferences.trackpadKeys + TrackpadSystemPreferences.dockKeys
        ) { stored[$0] }
        XCTAssertEqual(values, [
            "TrackpadThreeFingerHorizSwipeGesture": 2, "TrackpadThreeFingerDrag": 1, "showMissionControlGestureEnabled": 0,
        ])
    }

    /// Reading only: CFPreferences values of other domains, nothing written.
    func testReadingTheRealPreferencesKeepsToTheKnownKeys() {
        let preferences = readTrackpadSystemPreferences()
        let known = Set(TrackpadSystemPreferences.trackpadKeys)
        XCTAssertTrue(Set(preferences.trackpad.keys).isSubset(of: known))
        XCTAssertTrue(Set(preferences.bluetoothTrackpad.keys).isSubset(of: known))
        XCTAssertTrue(Set(preferences.dock.keys).isSubset(of: Set(TrackpadSystemPreferences.dockKeys)))
    }
}
