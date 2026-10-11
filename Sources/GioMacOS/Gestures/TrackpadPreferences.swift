import CoreFoundation
import Foundation
import GioCore

/// TG-04: numbers and booleans become integers (booleans 0 or 1); anything
/// else is left out, so macOS's default applies to it.
func preferenceValues(_ keys: [String], lookup: (String) -> Any?) -> [String: Int] {
    var values: [String: Int] = [:]
    for key in keys {
        if let number = lookup(key) as? NSNumber {
            values[key] = number.intValue
        }
    }
    return values
}

/// TG-04: the trackpad swipe settings macOS keeps for itself, read (never
/// written) from the built-in and Magic Trackpad domains and the Dock's.
/// Each domain is synchronized first, so a change made in System Settings
/// since the last read is seen. Any thread; a few `cfprefsd` round trips.
public func readTrackpadSystemPreferences() -> TrackpadSystemPreferences {
    func domain(_ name: String, _ keys: [String]) -> [String: Int] {
        let application = name as CFString
        CFPreferencesAppSynchronize(application)
        return preferenceValues(keys) { CFPreferencesCopyAppValue($0 as CFString, application) }
    }
    return TrackpadSystemPreferences(
        trackpad: domain("com.apple.AppleMultitouchTrackpad", TrackpadSystemPreferences.trackpadKeys),
        bluetoothTrackpad: domain("com.apple.driver.AppleBluetoothMultitouch.trackpad", TrackpadSystemPreferences.trackpadKeys),
        dock: domain("com.apple.dock", TrackpadSystemPreferences.dockKeys)
    )
}
