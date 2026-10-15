import Foundation
import os

/// PF-AC: `os_signpost` intervals and events on the latency-critical paths
/// (hotkey, action, reflow, reconcile, overlay prime, capture), shown in
/// Instruments under Points of Interest. Nearly free while no tool records:
/// the signposter checks `isEnabled` before formatting anything. Names are
/// static strings; no titles or app names are ever attached (rule 5).
public enum GioSignpost {
    public static let signposter = OSSignposter(subsystem: "com.gio.wm", category: .pointsOfInterest)

    /// A single moment (a hotkey reaching the tap).
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// Begin an interval; pass the state to `end` with the same name.
    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// `body` inside one interval.
    @discardableResult
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try body()
    }
}
