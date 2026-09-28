import Foundation

public struct WorkspacePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Tiling is opt-in for each physical display, including after relaunch.
    public func tilingEnabled(on display: String) -> Bool {
        defaults.bool(forKey: "gio.display.\(display).tiling")
    }

    public func setTilingEnabled(_ enabled: Bool, on display: String) {
        defaults.set(enabled, forKey: "gio.display.\(display).tiling")
    }

    /// Bounded point presets avoid unrepresentable or negative user-supplied gaps.
    public var gap: Int {
        let value = defaults.integer(forKey: "gio.tiling.gap")
        return [0, 8, 16].contains(value) ? value : 0
    }

    @discardableResult public func setGap(_ value: Int) -> Bool {
        guard [0, 8, 16].contains(value) else { return false }
        defaults.set(value, forKey: "gio.tiling.gap")
        return true
    }
}
