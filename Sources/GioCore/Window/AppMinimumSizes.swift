import CoreGraphics
import Foundation

/// PA-24: minimum sizes apps enforce, kept per app across launches.
/// `MinimumSizeBook` learns a window's minimum from one clamped write per
/// session; without this every launch laid WhatsApp (970 pt), Figma and
/// NoteX (900) out too narrow once and they overlapped their neighbour
/// until the next pass. Keyed by bundle identifier when known, else by
/// app name. Values only grow, like the book's.
public struct AppMinimumSizes: Equatable, Sendable {
    public private(set) var sizes: [String: CGSize] = [:]

    public init(sizes: [String: CGSize] = [:]) {
        self.sizes = sizes
    }

    public static func key(for window: ManagedWindow) -> String {
        window.bundleID.map { "bundle:\($0)" } ?? "name:\(window.application)"
    }

    public func size(for window: ManagedWindow) -> CGSize? {
        sizes[Self.key(for: window)]
    }

    /// Merge what one of the app's windows showed. True when it grew (the
    /// caller saves).
    @discardableResult
    public mutating func record(_ size: CGSize, for window: ManagedWindow, tolerance: CGFloat = 1) -> Bool {
        let key = Self.key(for: window)
        let known = sizes[key] ?? .zero
        let merged = CGSize(width: max(known.width, size.width), height: max(known.height, size.height))
        guard merged.width > known.width + tolerance || merged.height > known.height + tolerance else {
            return false
        }
        sizes[key] = merged
        return true
    }

    /// The minimums a pass lays out with: what this session learned for a
    /// window, else what its app showed before.
    public func effective(learned: [WindowID: CGSize], windows: [ManagedWindow]) -> [WindowID: CGSize] {
        guard !sizes.isEmpty else {
            return learned
        }
        var result = learned
        for window in windows where result[window.id] == nil {
            if let size = sizes[Self.key(for: window)] {
                result[window.id] = size
            }
        }
        return result
    }
}

/// PA-24: `AppMinimumSizes` on disk (a small JSON object of app key to
/// `[width, height]`). Regenerable, so the host keeps it in Caches; a
/// missing or unreadable file reads as empty. No shared state.
public struct AppMinimumSizeStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AppMinimumSizes {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data)
        else {
            return AppMinimumSizes()
        }
        var sizes: [String: CGSize] = [:]
        for (key, pair) in raw where pair.count == 2 && pair.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            sizes[key] = CGSize(width: pair[0], height: pair[1])
        }
        return AppMinimumSizes(sizes: sizes)
    }

    /// Replaces the file atomically; a failure keeps the old file.
    public func save(_ minimums: AppMinimumSizes) {
        let raw = minimums.sizes.mapValues { [Double($0.width), Double($0.height)] }
        guard let data = try? JSONEncoder().encode(raw) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
