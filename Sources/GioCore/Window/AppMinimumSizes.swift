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
///
/// FX-05: width and height are confirmed apart. An app clamps one axis on
/// one write and both on another (live: WhatsApp 970x600, then 970x0), so a
/// pair never matched and the width was learned again every launch. A
/// learning without evidence on an axis (0) leaves that axis alone.
public struct AppMinimumSizes: Equatable, Sendable {
    /// One axis of an app's minimum: the value and how often it was learned.
    public struct Axis: Equatable, Sendable {
        public var value: CGFloat
        public var seen: Int

        public init(value: CGFloat, seen: Int) {
            self.value = value
            self.seen = seen
        }

        var confirmed: CGFloat? {
            seen >= AppMinimumSizes.confirmations ? value : nil
        }
    }

    public struct Entry: Equatable, Sendable {
        public var width: Axis?
        public var height: Axis?

        public init(width: Axis? = nil, height: Axis? = nil) {
            self.width = width
            self.height = height
        }

        /// The confirmed axes (0 for one that is not); nil when neither is.
        var confirmed: CGSize? {
            let width = width?.confirmed ?? 0
            let height = height?.confirmed ?? 0
            return width > 0 || height > 0 ? CGSize(width: width, height: height) : nil
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
        entries.values.contains { $0.confirmed != nil }
    }

    /// The app's confirmed minimum (0 on an axis still a candidate); nil
    /// while neither axis is confirmed.
    public func size(for window: ManagedWindow) -> CGSize? {
        entries[Self.key(for: window)]?.confirmed
    }

    /// The app's window learned `size` (0 on an axis without evidence).
    /// True when the entry changed (the caller saves).
    @discardableResult
    public mutating func record(_ size: CGSize, for window: ManagedWindow, tolerance: CGFloat = 1) -> Bool {
        let key = Self.key(for: window)
        var entry = entries[key] ?? Entry()
        func learn(_ value: CGFloat, into axis: inout Axis?) {
            guard value > 0 else {
                return
            }
            guard let known = axis, abs(known.value - value) <= tolerance else {
                axis = Axis(value: value, seen: 1)
                return
            }
            if known.seen < Self.confirmations {
                axis = Axis(value: known.value, seen: known.seen + 1)
            }
        }
        learn(size.width, into: &entry.width)
        learn(size.height, into: &entry.height)
        guard entry != entries[key] else {
            return false
        }
        entries[key] = entry
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
            if let size = size(for: window) {
                result[window.id] = size
            }
        }
        return result
    }
}

/// PA-24: `AppMinimumSizes` on disk: `{"version": 3, "apps": {key:
/// [width, widthSeen, height, heightSeen]}}` (0 for an axis never learned).
/// Regenerable, so the host keeps it in Caches; a missing or unreadable file
/// reads as empty, the first format (single clamps, BUG-2) too, and the
/// second (pairs, FX-05) keeps only its confirmed pairs. No shared state.
public struct AppMinimumSizeStore: Sendable {
    private static let version = 3
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
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return AppMinimumSizes()
        }
        var entries: [String: AppMinimumSizes.Entry] = [:]
        for (key, values) in file.apps where values.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            func axis(_ value: Double, _ seen: Double) -> AppMinimumSizes.Axis? {
                value > 0 && seen >= 1 ? AppMinimumSizes.Axis(value: value, seen: Int(seen)) : nil
            }
            let entry: AppMinimumSizes.Entry
            switch (file.version, values.count) {
            case (Self.version, 4):
                entry = AppMinimumSizes.Entry(width: axis(values[0], values[1]), height: axis(values[2], values[3]))
            case (2, 3) where values[2] >= Double(AppMinimumSizes.confirmations):
                entry = AppMinimumSizes.Entry(width: axis(values[0], values[2]), height: axis(values[1], values[2]))
            default:
                continue
            }
            if entry.width != nil || entry.height != nil {
                entries[key] = entry
            }
        }
        return AppMinimumSizes(entries: entries)
    }

    /// Replaces the file atomically; a failure keeps the old file.
    public func save(_ minimums: AppMinimumSizes) {
        let apps = minimums.entries.mapValues { entry in
            [entry.width, entry.height].flatMap { axis in [Double(axis?.value ?? 0), Double(axis?.seen ?? 0)] }
        }
        guard let data = try? JSONEncoder().encode(File(version: Self.version, apps: apps)) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
