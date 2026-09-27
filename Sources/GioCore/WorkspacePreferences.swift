import Foundation

/// Workspace labels are presentation only; numeric IDs remain stable across launches.
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

    public func name(for number: Int) -> String {
        guard (1...4).contains(number) else { return "Workspace \(number)" }
        return defaults.string(forKey: "gio.workspace.\(number).name") ?? "Workspace \(number)"
    }

    @discardableResult public func rename(_ number: Int, to input: String) -> Bool {
        guard (1...4).contains(number) else { return false }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return false }
        defaults.set(name, forKey: "gio.workspace.\(number).name")
        return true
    }
}
