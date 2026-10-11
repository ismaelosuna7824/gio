import Foundation

/// TG-04: the trackpad swipe settings macOS keeps for itself, as integers
/// read (never written) from `com.apple.AppleMultitouchTrackpad` (built-in
/// trackpad), `com.apple.driver.AppleBluetoothMultitouch.trackpad` (Magic
/// Trackpad) and `com.apple.dock`; booleans are 0 or 1. A key missing from
/// every domain is macOS's default.
public struct TrackpadSystemPreferences: Equatable, Sendable {
    public static let trackpadKeys = [
        "TrackpadThreeFingerHorizSwipeGesture", "TrackpadThreeFingerVertSwipeGesture",
        "TrackpadFourFingerHorizSwipeGesture", "TrackpadFourFingerVertSwipeGesture", "TrackpadThreeFingerDrag",
    ]
    public static let dockKeys = ["showMissionControlGestureEnabled", "showAppExposeGestureEnabled"]

    public var trackpad: [String: Int]
    public var bluetoothTrackpad: [String: Int]
    public var dock: [String: Int]

    public init(trackpad: [String: Int] = [:], bluetoothTrackpad: [String: Int] = [:], dock: [String: Int] = [:]) {
        self.trackpad = trackpad
        self.bluetoothTrackpad = bluetoothTrackpad
        self.dock = dock
    }

    /// Every value a trackpad domain holds for `key`; the default when none does.
    func trackpadValues(_ key: String, default fallback: Int) -> [Int] {
        let values = [trackpad[key], bluetoothTrackpad[key]].compactMap { $0 }
        return values.isEmpty ? [fallback] : values
    }

    func dockFlag(_ key: String, default fallback: Bool) -> Bool {
        dock[key].map { $0 != 0 } ?? fallback
    }
}

/// TG-04: a swipe macOS performs itself.
public enum SystemTrackpadGesture: String, Equatable, Hashable, Sendable {
    case fullScreenSwipe = "full-screen-swipe"
    case pageSwipe = "page-swipe"
    case missionControl = "mission-control"
    case appExpose = "app-expose"
    case threeFingerDrag = "three-finger-drag"

    public var title: String {
        switch self {
        case .fullScreenSwipe: return "Swipe between full-screen applications"
        case .pageSwipe: return "Swipe between pages"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .threeFingerDrag: return "three-finger drag"
        }
    }

    /// Where the user turns it off or moves it to other fingers.
    public var settingsPath: String {
        switch self {
        case .fullScreenSwipe, .pageSwipe, .missionControl, .appExpose:
            return "System Settings > Trackpad > More Gestures > \(title)"
        case .threeFingerDrag:
            return "System Settings > Accessibility > Pointer Control > Trackpad Options > Dragging style"
        }
    }
}

/// TG-04: Gio's gestures, as conflicts name them.
public enum GioTrackpadGesture: String, Equatable, Hashable, Sendable {
    case scroll
    case workspaceSwipe = "workspace-swipe"
    case overview

    var title: String {
        switch self {
        case .scroll: return "Scroll"
        case .workspaceSwipe: return "Workspace swipe"
        case .overview: return "Overview swipe"
        }
    }
}

/// TG-04: one Gio gesture that macOS performs too on the same swipe.
public struct GestureConflict: Equatable, Hashable, Sendable {
    public var gesture: GioTrackpadGesture
    public var fingers: Int
    public var system: SystemTrackpadGesture

    public init(gesture: GioTrackpadGesture, fingers: Int, system: SystemTrackpadGesture) {
        self.gesture = gesture
        self.fingers = fingers
        self.system = system
    }
}

/// TG-04: which enabled Gio gestures macOS also acts on. Horizontal swipe
/// keys: 1 is swipe between pages (three fingers only), 2 full-screen apps;
/// vertical keys: 2 is Mission Control (up, when the Dock's Mission Control
/// gesture is on, the default) and App Exposé (down, when it is on, off by
/// default). macOS's defaults are 2 for all four swipes. Three-finger drag
/// turns every three-finger swipe into a mouse drag. Five fingers meet no
/// swipe. Only gestures that are on count.
public func detectGestureConflicts(
    _ config: GesturesSectionConfig, preferences: TrackpadSystemPreferences
) -> [GestureConflict] {
    let missionControl = preferences.dockFlag("showMissionControlGestureEnabled", default: true)
    let appExpose = preferences.dockFlag("showAppExposeGestureEnabled", default: false)
    let drag = preferences.trackpadValues("TrackpadThreeFingerDrag", default: 0).contains { $0 != 0 }
    func name(_ fingers: Int) -> String? {
        switch fingers {
        case 3: return "Three"
        case 4: return "Four"
        default: return nil
        }
    }
    func horizontal(_ fingers: Int) -> [SystemTrackpadGesture] {
        guard let count = name(fingers) else {
            return []
        }
        let values = preferences.trackpadValues("Trackpad\(count)FingerHorizSwipeGesture", default: 2)
        if values.contains(2) {
            return [.fullScreenSwipe]
        }
        return fingers == 3 && values.contains(1) ? [.pageSwipe] : []
    }
    func vertical(_ fingers: Int, upOnly: Bool) -> [SystemTrackpadGesture] {
        guard let count = name(fingers),
              preferences.trackpadValues("Trackpad\(count)FingerVertSwipeGesture", default: 2).contains(2)
        else {
            return []
        }
        var found: [SystemTrackpadGesture] = []
        if missionControl {
            found.append(.missionControl)
        }
        if appExpose, !upOnly {
            found.append(.appExpose)
        }
        return found
    }
    var conflicts: [GestureConflict] = []
    func add(_ gesture: GioTrackpadGesture, _ fingers: Int, _ systems: [SystemTrackpadGesture]) {
        var all = systems
        if drag, fingers == 3 {
            all.append(.threeFingerDrag)
        }
        conflicts += all.map { GestureConflict(gesture: gesture, fingers: fingers, system: $0) }
    }
    if config.scroll {
        add(.scroll, config.scrollFingers, horizontal(config.scrollFingers))
    }
    if config.workspaceSwipe {
        add(.workspaceSwipe, config.workspaceFingers, vertical(config.workspaceFingers, upOnly: false))
    }
    if config.overview {
        add(.overview, config.overviewFingers, vertical(config.overviewFingers, upOnly: true))
    }
    return conflicts
}

/// TG-04: the warning shown in Diagnostics, the Overview and Settings.
public func gestureConflictMessage(_ conflict: GestureConflict) -> String {
    "\(conflict.gesture.title) (\(conflict.fingers) fingers) also triggers macOS \(conflict.system.title): "
        + "change it in \(conflict.system.settingsPath), or give Gio other fingers."
}

/// TG-04: `gestures conflict=<gesture-fingers:system,...>` (or `none`) once,
/// then on change.
public struct GestureConflictLogGate: Sendable {
    private var last: [GestureConflict]?

    public init() {}

    public mutating func line(for conflicts: [GestureConflict]) -> String? {
        guard conflicts != last else {
            return nil
        }
        last = conflicts
        let names = conflicts.map { "\($0.gesture.rawValue)-\($0.fingers):\($0.system.rawValue)" }
        return "gestures conflict=" + (names.isEmpty ? "none" : names.joined(separator: ","))
    }
}
