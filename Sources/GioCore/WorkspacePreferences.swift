import Foundation

/// Workspace labels are presentation only; numeric IDs remain stable across launches.
public struct WorkspacePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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
