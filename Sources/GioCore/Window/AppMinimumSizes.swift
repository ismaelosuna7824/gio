import CoreGraphics
import Foundation

/// PA-24: minimum sizes apps enforce, kept per app across launches.
/// `MinimumSizeBook` learns a window's minimum from one clamped write per
/// session; without this every launch laid WhatsApp (970 pt), Figma and
/// NoteX (900) out too narrow once and they overlapped their neighbour
/// until the next pass. Keyed by bundle identifier when known, else by
/// app name.
///
/// BUG-2: one clamp can be read before the app finished resizing (live:
/// Figma's old maximized 1784 pt width, learned as its minimum). A value is
/// only a candidate until it is learned again (another session, or another
/// window of the app; `tolerance`); only confirmed values lay windows out. A
/// different value replaces the candidate, so a transient one never
/// survives and a real change (an app update) is confirmed again.
public struct AppMinimumSizes: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var size: CGSize
        public var seen: Int

        public init(size: CGSize, seen: Int) {
            self.size = size
            self.seen = seen
        }
    }

    public static let confirmations = 2
    public private(set) var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static func key(for window: ManagedWindow) -> String {
        window.bundleID.map { "bundle:\($0)" } ?? "name:\(window.application)"
    }

    /// Whether any app has a confirmed minimum (no layout work otherwise).
    public var hasConfirmed: Bool {
        entries.values.contains { $0.seen >= Self.confirmations }
    }

    /// The app's confirmed minimum; nil while it is a candidate.
    public func size(for window: ManagedWindow) -> CGSize? {
        confirmed(Self.key(for: window))
    }

    private func confirmed(_ key: String) -> CGSize? {
        entries[key].flatMap { $0.seen >= Self.confirmations ? $0.size : nil }
    }

    /// The app's window learned `size`. True when the entry changed (the
    /// caller saves).
    @discardableResult
    public mutating func record(_ size: CGSize, for window: ManagedWindow, tolerance: CGFloat = 1) -> Bool {
        let key = Self.key(for: window)
        guard let known = entries[key],
              abs(known.size.width - size.width) <= tolerance, abs(known.size.height - size.height) <= tolerance
        else {
            entries[key] = Entry(size: size, seen: 1)
            return true
        }
        guard known.seen < Self.confirmations else {
            return false
        }
        entries[key] = Entry(size: known.size, seen: known.seen + 1)
        return true
    }

    /// The minimums a pass lays out with: what this session learned for a
    /// window, else its app's confirmed minimum.
    public func effective(learned: [WindowID: CGSize], windows: [ManagedWindow]) -> [WindowID: CGSize] {
        guard hasConfirmed else {
            return learned
        }
        var result = learned
        for window in windows where result[window.id] == nil {
            if let size = confirmed(Self.key(for: window)) {
                result[window.id] = size
            }
        }
        return result
    }
}

/// PA-24: `AppMinimumSizes` on disk: `{"version": 2, "apps": {key:
/// [width, height, seen]}}`. Regenerable, so the host keeps it in Caches; a
/// missing, unreadable or first-format file (single clamps, BUG-2) reads as
/// empty. No shared state.
public struct AppMinimumSizeStore: Sendable {
    private static let version = 2
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private struct File: Codable {
        var version: Int
        var apps: [String: [Double]]
    }

    public func load() -> AppMinimumSizes {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version
        else {
            return AppMinimumSizes()
        }
        var entries: [String: AppMinimumSizes.Entry] = [:]
        for (key, values) in file.apps
        where values.count == 3 && values.allSatisfy({ $0.isFinite && $0 >= 0 }) && values[2] >= 1 {
            entries[key] = AppMinimumSizes.Entry(
                size: CGSize(width: values[0], height: values[1]), seen: Int(values[2])
            )
        }
        return AppMinimumSizes(entries: entries)
    }

    /// Replaces the file atomically; a failure keeps the old file.
    public func save(_ minimums: AppMinimumSizes) {
        let apps = minimums.entries.mapValues { [Double($0.size.width), Double($0.size.height), Double($0.seen)] }
        guard let data = try? JSONEncoder().encode(File(version: Self.version, apps: apps)) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
