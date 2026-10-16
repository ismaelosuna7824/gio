import Foundation

/// TG-02 `[gestures]`: trackpad swipes read from MultitouchSupport. Consumed
/// by `GestureController` (`GioSession`) and the touch source in the host.
/// Two fingers are not offered: that is the system's own scrolling, which
/// Gio would have to swallow from the event stream (Input Monitoring, tap
/// timeouts); three to five fingers reach macOS's own swipes instead, which
/// `detectGestureConflicts` reports.
public struct GesturesSectionConfig: Equatable, Sendable {
    public static let fingerRange = 3...5
    public static let sensitivityRange = 0.1...5.0
    /// TG-08: `swipe-distance`, a fraction of the trackpad height.
    public static let swipeDistanceRange = 0.05...0.5

    /// Horizontal swipe scrolls the strip, following the fingers.
    public var scroll: Bool
    public var scrollFingers: Int
    /// Strip travel per trackpad width, in viewport widths.
    public var scrollSensitivity: Double
    /// Content follows the fingers (macOS natural scrolling); false inverts
    /// both the scroll and the workspace swipe.
    public var natural: Bool
    /// Vertical swipe switches workspace, one per swipe.
    public var workspaceSwipe: Bool
    public var workspaceFingers: Int
    /// Swipe up opens or closes the workspace overview.
    public var overview: Bool
    public var overviewFingers: Int
    /// TG-08: vertical travel (fraction of the trackpad height) before a
    /// workspace swipe or the overview fires.
    public var swipeDistance: Double

    public init(
        scroll: Bool = true, scrollFingers: Int = 3, scrollSensitivity: Double = 1.0, natural: Bool = true,
        workspaceSwipe: Bool = true, workspaceFingers: Int = 3, overview: Bool = false, overviewFingers: Int = 4,
        swipeDistance: Double = GestureRecognizerSettings.defaultSwipeDistance
    ) {
        self.scroll = scroll
        self.scrollFingers = scrollFingers
        self.scrollSensitivity = scrollSensitivity
        self.natural = natural
        self.workspaceSwipe = workspaceSwipe
        self.workspaceFingers = workspaceFingers
        self.overview = overview
        self.overviewFingers = overviewFingers
        self.swipeDistance = swipeDistance
    }

    public var anyEnabled: Bool {
        scroll || workspaceSwipe || overview
    }

    /// The workspace swipe and the overview both swipe vertically.
    public var verticalConflict: Bool {
        workspaceSwipe && overview && workspaceFingers == overviewFingers
    }

    public var recognizerSettings: GestureRecognizerSettings {
        var vertical: Set<Int> = []
        if workspaceSwipe {
            vertical.insert(workspaceFingers)
        }
        if overview {
            vertical.insert(overviewFingers)
        }
        return GestureRecognizerSettings(
            horizontalFingers: scroll ? scrollFingers : nil, verticalFingers: vertical, swipeDistance: swipeDistance
        )
    }
}

func applyGesturesKey(
    _ key: String, value: ConfigValue, line: Int, warnings: inout [String], config: inout GioConfig
) {
    let defaults = GesturesSectionConfig()
    func flag(_ fallback: Bool, _ set: (Bool) -> Void) {
        guard case .bool(let enabled) = value else {
            warnings.append("line \(line): gestures.\(key) expects true or false, using \(fallback)")
            return
        }
        set(enabled)
    }
    func fingers(_ fallback: Int, _ set: (Int) -> Void) {
        let range = GesturesSectionConfig.fingerRange
        guard let number = value.number, number == number.rounded(), range.contains(Int(number)) else {
            warnings.append("line \(line): gestures.\(key) expects 3, 4 or 5 fingers, using \(fallback)")
            return
        }
        set(Int(number))
    }
    func number(_ range: ClosedRange<Double>, _ fallback: Double, _ set: (Double) -> Void) {
        guard let number = value.number, number.isFinite else {
            warnings.append(
                "line \(line): gestures.\(key) expects a number from \(range.lowerBound) to \(range.upperBound), using \(fallback)"
            )
            return
        }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        if clamped != number {
            warnings.append(
                "line \(line): gestures.\(key) clamped to \(clamped) (valid \(range.lowerBound)-\(range.upperBound))"
            )
        }
        set(clamped)
    }
    switch key {
    case "scroll":
        flag(defaults.scroll) { config.gestures.scroll = $0 }
    case "scroll-fingers":
        fingers(defaults.scrollFingers) { config.gestures.scrollFingers = $0 }
    case "scroll-sensitivity":
        number(GesturesSectionConfig.sensitivityRange, defaults.scrollSensitivity) {
            config.gestures.scrollSensitivity = $0
        }
    case "swipe-distance":
        number(GesturesSectionConfig.swipeDistanceRange, defaults.swipeDistance) {
            config.gestures.swipeDistance = $0
        }
    case "natural":
        flag(defaults.natural) { config.gestures.natural = $0 }
    case "workspace-swipe":
        flag(defaults.workspaceSwipe) { config.gestures.workspaceSwipe = $0 }
    case "workspace-fingers":
        fingers(defaults.workspaceFingers) { config.gestures.workspaceFingers = $0 }
    case "overview":
        flag(defaults.overview) { config.gestures.overview = $0 }
    case "overview-fingers":
        fingers(defaults.overviewFingers) { config.gestures.overviewFingers = $0 }
    default:
        warnings.append("line \(line): unknown gestures key '\(key)', ignored")
    }
}

/// After the whole file: two vertical gestures on one finger count cannot
/// both run. The workspace swipe keeps its fingers; the overview turns off.
func validateGestures(_ config: inout GioConfig, warnings: inout [String]) {
    guard config.gestures.verticalConflict else {
        return
    }
    let fingers = config.gestures.overviewFingers
    warnings.append(
        "gestures.overview-fingers = \(fingers) is also gestures.workspace-fingers; both swipe vertically, overview turned off"
    )
    config.gestures.overview = false
}

/// TG-02 Settings form for `[gestures]`: values in, problems and edits out.
public struct GesturesSettingsForm: Equatable, Sendable {
    public var scroll: Bool
    public var scrollFingers: Int
    public var scrollSensitivity: Double
    public var natural: Bool
    public var workspaceSwipe: Bool
    public var workspaceFingers: Int
    public var overview: Bool
    public var overviewFingers: Int
    public var swipeDistance: Double

    public init(config: GesturesSectionConfig) {
        scroll = config.scroll
        scrollFingers = config.scrollFingers
        scrollSensitivity = config.scrollSensitivity
        natural = config.natural
        workspaceSwipe = config.workspaceSwipe
        workspaceFingers = config.workspaceFingers
        overview = config.overview
        overviewFingers = config.overviewFingers
        swipeDistance = config.swipeDistance
    }

    var section: GesturesSectionConfig {
        GesturesSectionConfig(
            scroll: scroll, scrollFingers: scrollFingers, scrollSensitivity: scrollSensitivity, natural: natural,
            workspaceSwipe: workspaceSwipe, workspaceFingers: workspaceFingers,
            overview: overview, overviewFingers: overviewFingers, swipeDistance: swipeDistance
        )
    }

    public var problems: [String] {
        var found: [String] = []
        let range = GesturesSectionConfig.sensitivityRange
        if !(scrollSensitivity.isFinite && range.contains(scrollSensitivity)) {
            found.append("Sensitivity must be \(range.lowerBound) to \(range.upperBound).")
        }
        if !(swipeDistance.isFinite && GesturesSectionConfig.swipeDistanceRange.contains(swipeDistance)) {
            found.append("Swipe distance must be 5% to 50% of the trackpad height.")
        }
        let fingers = GesturesSectionConfig.fingerRange
        if ![scrollFingers, workspaceFingers, overviewFingers].allSatisfy(fingers.contains) {
            found.append("Gestures use 3 to 5 fingers.")
        }
        if section.verticalConflict {
            found.append("Workspace swipe and overview both use \(overviewFingers) fingers; pick different counts.")
        }
        return found
    }

    public var edits: [ConfigEdit] {
        // Two decimals keep the slider's value readable in config.toml.
        let sensitivity = (scrollSensitivity * 100).rounded() / 100
        let distance = (swipeDistance * 100).rounded() / 100
        return [
            .set(table: "gestures", key: "scroll", value: .bool(scroll)),
            .set(table: "gestures", key: "scroll-fingers", value: .int(scrollFingers)),
            .set(table: "gestures", key: "scroll-sensitivity", value: .number(sensitivity)),
            .set(table: "gestures", key: "natural", value: .bool(natural)),
            .set(table: "gestures", key: "workspace-swipe", value: .bool(workspaceSwipe)),
            .set(table: "gestures", key: "workspace-fingers", value: .int(workspaceFingers)),
            .set(table: "gestures", key: "overview", value: .bool(overview)),
            .set(table: "gestures", key: "overview-fingers", value: .int(overviewFingers)),
            .set(table: "gestures", key: "swipe-distance", value: .number(distance)),
        ]
    }
}
