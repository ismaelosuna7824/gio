import CoreGraphics
import Foundation

// SM-04: bookkeeping of the pre-captured window image cache. Generic over
// the image so Core stays free of platform image types; the session stores
// CGImages. Session queue only, no locking.

public struct SnapshotCacheEntry<Image> {
    public let image: Image
    /// Frame the window had when captured (Cocoa).
    public let frame: CGRect
    public let capturedAt: TimeInterval
    public var lastUsed: TimeInterval
    public let pixels: Int

    public init(image: Image, frame: CGRect, capturedAt: TimeInterval, lastUsed: TimeInterval, pixels: Int) {
        self.image = image
        self.frame = frame
        self.capturedAt = capturedAt
        self.lastUsed = lastUsed
        self.pixels = pixels
    }
}

/// Total pixels the cache may hold: 12 display-fulls (2 x 6, e.g. six
/// windows at twice the display size).
public func snapshotCacheCapPixels(displayPixels: Int) -> Int {
    displayPixels * 12
}

/// Longest an image may be trusted; older ones are treated as misses so the
/// overlay never shows stale content from minutes ago.
public let snapshotMaxAge: TimeInterval = 60

/// An entry is usable when it is fresh and its size still matches the
/// window's current size (position does not matter: layers fly from the
/// window's current frame).
public func snapshotEntryUsable<Image>(
    _ entry: SnapshotCacheEntry<Image>, currentFrame: CGRect, now: TimeInterval,
    maxAge: TimeInterval = snapshotMaxAge, tolerance: CGFloat = 2
) -> Bool {
    now - entry.capturedAt <= maxAge
        && abs(entry.frame.width - currentFrame.width) <= tolerance
        && abs(entry.frame.height - currentFrame.height) <= tolerance
}

public struct SnapshotCache<Image> {
    private var entries: [WindowID: SnapshotCacheEntry<Image>] = [:]

    public init() {}

    public var count: Int { entries.count }
    public var totalPixels: Int { entries.values.reduce(0) { $0 + $1.pixels } }
    public var ids: Set<WindowID> { Set(entries.keys) }

    public func entry(_ id: WindowID) -> SnapshotCacheEntry<Image>? {
        entries[id]
    }

    public mutating func store(_ id: WindowID, image: Image, frame: CGRect, pixels: Int, at now: TimeInterval) {
        entries[id] = SnapshotCacheEntry(image: image, frame: frame, capturedAt: now, lastUsed: now, pixels: pixels)
    }

    /// Mark entries as just used (the LRU order).
    public mutating func touch(_ ids: some Sequence<WindowID>, at now: TimeInterval) {
        for id in ids {
            entries[id]?.lastUsed = now
        }
    }

    public mutating func evict(_ ids: some Sequence<WindowID>) {
        for id in ids {
            entries.removeValue(forKey: id)
        }
    }

    /// Drop every entry outside `keep` (windows that closed, minimized or
    /// left the managed set). Returns the dropped ids.
    @discardableResult
    public mutating func retain(only keep: Set<WindowID>) -> [WindowID] {
        let dropped = entries.keys.filter { !keep.contains($0) }.sorted()
        evict(dropped)
        return dropped
    }

    /// Least recently used first until the total is within `capPixels`.
    @discardableResult
    public mutating func enforce(capPixels: Int) -> [WindowID] {
        var evicted: [WindowID] = []
        var total = totalPixels
        let order = entries.sorted { lhs, rhs in
            lhs.value.lastUsed != rhs.value.lastUsed ? lhs.value.lastUsed < rhs.value.lastUsed : lhs.key < rhs.key
        }
        for (id, entry) in order where total > capPixels {
            entries.removeValue(forKey: id)
            evicted.append(id)
            total -= entry.pixels
        }
        return evicted
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// Age of the oldest image among `ids`, in milliseconds (0 for none).
    public func maxAgeMilliseconds(of ids: some Sequence<WindowID>, now: TimeInterval) -> Int {
        let ages = ids.compactMap { entries[$0] }.map { now - $0.capturedAt }
        return Int(((ages.max() ?? 0) * 1000).rounded())
    }
}

/// What to capture after a settle, in priority order: the visible windows
/// (whole columns, in column order: a stacked window may be partly hidden), the window(s) of the column just left of the visible
/// span, then just right of it, then `extras` (focused windows of adjacent
/// workspaces). No duplicates.
public func snapshotCaptureSet(
    columns: [[WindowID]], visible: Set<WindowID>, extras: [WindowID]
) -> [WindowID] {
    var result: [WindowID] = []
    var seen: Set<WindowID> = []
    func add(_ ids: [WindowID]) {
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
    }
    let visibleColumns = columns.indices.filter { index in columns[index].contains { visible.contains($0) } }
    if let first = visibleColumns.first, let last = visibleColumns.last {
        for index in visibleColumns {
            add(columns[index])
        }
        if first > 0 {
            add(columns[first - 1])
        }
        if last + 1 < columns.count {
            add(columns[last + 1])
        }
    }
    add(extras)
    return result
}
