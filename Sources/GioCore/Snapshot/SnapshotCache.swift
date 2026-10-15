import CoreGraphics
import Foundation

// SM-04: bookkeeping of the pre-captured window image cache. Generic over
// the image so Core stays free of platform image types; the session stores
// CGImages. Session queue only, no locking.

/// PF-AH: every capture comes back in this one colour space, the one the
/// overlay panels are drawn in, so Core Animation never converts an image on
/// the main thread at commit. A window captured on one display and flown on
/// another (another colour profile) cost ~23 ms of CMS conversion per image
/// per flight there; the WindowServer now matches the panel to each display
/// on the GPU instead.
public let snapshotColorSpaceName = CGColorSpace.displayP3 as String

public struct SnapshotCacheEntry<Image> {
    public let image: Image
    /// Frame the window had when captured (Cocoa).
    public let frame: CGRect
    public let capturedAt: TimeInterval
    public var lastUsed: TimeInterval
    public let pixels: Int
    /// SM-22: the resolution the image was captured at.
    public let resolution: SnapshotResolution
    /// SM-27/SM-30: the fill a resize shows where the frame outgrows the
    /// image (`snapshotContentFill`); nil for a see-through capture.
    public let fill: ThemeColor?

    public init(
        image: Image, frame: CGRect, capturedAt: TimeInterval, lastUsed: TimeInterval, pixels: Int,
        resolution: SnapshotResolution = .full, fill: ThemeColor? = nil
    ) {
        self.image = image
        self.frame = frame
        self.capturedAt = capturedAt
        self.lastUsed = lastUsed
        self.pixels = pixels
        self.resolution = resolution
        self.fill = fill
    }

    /// SM-27: the image as a layer draws it, at the size it was captured at.
    public var face: SnapshotFace<Image> {
        SnapshotFace(image: image, size: frame.size, fill: fill)
    }
}

/// SM-22: the resolution of a window image relative to the backing scale
/// of its display. The shown strips are captured at full resolution; the
/// windows of hidden workspaces (seen only during a ~350 ms switch slide,
/// then replaced by the real window) at half, a quarter of the pixels.
public enum SnapshotResolution: String, Equatable, Sendable {
    case full, half

    /// Factor applied to the backing scale for the capture size.
    public var scale: CGFloat {
        switch self {
        case .full: return 1
        case .half: return 0.5
        }
    }
}

/// SM-22: full resolution for a window of a shown strip (`shown`), half for
/// any other (a hidden workspace's).
public func snapshotCaptureResolution(_ id: WindowID, shown: Set<WindowID>) -> SnapshotResolution {
    shown.contains(id) ? .full : .half
}

/// SM-22: one image the cap evicted, and the resolution it had.
public struct SnapshotEviction: Equatable, Sendable {
    public let id: WindowID
    public let resolution: SnapshotResolution

    public init(id: WindowID, resolution: SnapshotResolution) {
        self.id = id
        self.resolution = resolution
    }
}

/// Total pixels the cache may hold, backdrops included (SM-20): 8
/// display-fulls. The heaviest typical set a flight needs at once (every
/// window maximized, the shown workspace in the middle of three: the
/// visible column, both neighbour columns, the focused windows of both
/// adjacent workspaces) is five window images plus the backdrop, about 6;
/// the remaining 2 hold coverage of other workspaces. SM-11: every image
/// counts, both sizes of a window included. SM-13: windows off screen and
/// away from the viewport are evicted first, then sizes a window is not at
/// now; backdrops count but are never evicted. SM-22: never above 3 % of
/// the physical memory at 4 bytes a pixel (an 8 GB Mac with a large
/// display); the shown strips still win over it (`enforce` pins them).
public func snapshotCacheCapPixels(displayPixels: Int, physicalMemory: UInt64) -> Int {
    let ram = physicalMemory * snapshotCacheRAMPercent / 100 / 4
    return min(displayPixels * 8, Int(clamping: ram))
}

/// SM-22: share of the physical memory the window images may use.
public let snapshotCacheRAMPercent: UInt64 = 3

/// SM-22: `snapshot cache cap pixels=N ramMB=N`, logged once at start.
public func snapshotCacheCapLogLine(capPixels: Int, physicalMemory: UInt64) -> String {
    "snapshot cache cap pixels=\(capPixels) ramMB=\(physicalMemory / 1_048_576)"
}

/// SM-11: images kept per window, one per size (Alt+F toggles between two).
public let snapshotSizesPerWindow = 2

/// Age past which an image counts as stale: a settle re-captures a stale
/// image of a shown strip, memory pressure drops the stale images of other
/// workspaces, and a window without a frame loses them. SM-24: never a reason
/// not to fly an image of the window's current size (a parked window cannot
/// be captured again; an old picture beats a hole or the AX motion).
public let snapshotMaxAge: TimeInterval = 180

/// SM-09: a settle refresh re-captures an image older than this even when
/// nothing marked it dirty (a window may repaint without any signal).
/// SM-11: also the age up to which an image of another size may fly (SM-27:
/// at its own size, cropped or over its fill, never scaled).
public let snapshotSoftAge: TimeInterval = 30

/// SM-09: the per-display backdrop (desktop, icons, unmanaged windows) is
/// re-captured after this age, or sooner when the unmanaged window set changes.
public let snapshotBackdropMaxAge: TimeInterval = 300

/// Why a capture ran: the settle refresh, a dirty signal, or a debug use.
public enum SnapshotCaptureReason: String, Equatable, Sendable {
    case settle, typing, focus, new, size, backdrop, measure, overview
}

/// SM-09: a display backdrop captured without the managed windows.
public struct SnapshotBackdropEntry<Image> {
    public let image: Image
    public let displayFrame: CGRect
    public let capturedAt: TimeInterval
    public let pixels: Int

    public init(image: Image, displayFrame: CGRect, capturedAt: TimeInterval, pixels: Int) {
        self.image = image
        self.displayFrame = displayFrame
        self.capturedAt = capturedAt
        self.pixels = pixels
    }
}

public func snapshotBackdropUsable<Image>(
    _ entry: SnapshotBackdropEntry<Image>, now: TimeInterval, maxAge: TimeInterval = snapshotBackdropMaxAge
) -> Bool {
    now - entry.capturedAt <= maxAge
}

func snapshotSameSize(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
    abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// SM-11: the image a flight uses. SM-27: with the image of the target size
/// (shown instead, SM-32) and how the layer shows the window without stretching it.
public struct SnapshotCacheUse<Image> {
    public let entry: SnapshotCacheEntry<Image>
    /// Captured at another size than the start frame (only while younger
    /// than the soft age).
    public let otherSize: Bool
    /// The newest image of the target frame's size, whatever its age (the
    /// start image itself on a move); nil when none is cached.
    public let target: SnapshotCacheEntry<Image>?
    /// Nil for a pure move with an image of the window's size.
    public let resize: SnapshotResizeMode?
}

public struct SnapshotCache<Image> {
    /// SM-11: up to `snapshotSizesPerWindow` entries per window, one per
    /// size (2 pt tolerance; the latest capture of a size replaces it).
    private var entries: [WindowID: [SnapshotCacheEntry<Image>]] = [:]
    /// One per display, looked up by the display frame (a handful at most).
    private var backdrops: [SnapshotBackdropEntry<Image>] = []

    public init() {}

    /// Windows with at least one image.
    public var count: Int { entries.count }
    /// Images, every size of every window.
    public var imageCount: Int { entries.values.reduce(0) { $0 + $1.count } }
    public var totalPixels: Int { entries.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.pixels } } }
    public var ids: Set<WindowID> { Set(entries.keys) }

    /// The newest image of the window, whatever its size.
    public func entry(_ id: WindowID) -> SnapshotCacheEntry<Image>? {
        entries[id]?.max { $0.capturedAt < $1.capturedAt }
    }

    /// The newest image of the window captured at `frame`'s size.
    public func entry(_ id: WindowID, matching frame: CGRect, tolerance: CGFloat = 2) -> SnapshotCacheEntry<Image>? {
        entries[id]?.filter { snapshotSameSize($0.frame, frame, tolerance: tolerance) }.max { $0.capturedAt < $1.capturedAt }
    }

    public func entries(of id: WindowID) -> [SnapshotCacheEntry<Image>] {
        entries[id] ?? []
    }

    /// SM-11: the image a flight from `startFrame` uses: the newest one of
    /// that size, whatever its age (SM-24); otherwise the newest image of
    /// another size while younger than `softAge`. No start frame: the
    /// newest image. Nil: the flight falls back. SM-27: with the newest image
    /// of `targetFrame`'s size (any age, like the start size) and the
    /// resize mode the layer draws with.
    public func usableEntry(
        _ id: WindowID, startFrame: CGRect?, targetFrame: CGRect? = nil, now: TimeInterval,
        softAge: TimeInterval = snapshotSoftAge, tolerance: CGFloat = 2
    ) -> SnapshotCacheUse<Image>? {
        let chosen: (entry: SnapshotCacheEntry<Image>, otherSize: Bool)
        if let startFrame {
            if let match = entry(id, matching: startFrame, tolerance: tolerance) {
                chosen = (match, false)
            } else if let newest = entry(id), now - newest.capturedAt <= softAge {
                chosen = (newest, true)
            } else {
                return nil
            }
        } else if let newest = entry(id) {
            chosen = (newest, false)
        } else {
            return nil
        }
        let target = targetFrame.flatMap { entry(id, matching: $0, tolerance: tolerance) }
        let from = startFrame?.size ?? chosen.entry.frame.size
        let resize = snapshotResizeMode(
            image: chosen.entry.frame.size, target: target?.frame.size, from: from, to: targetFrame?.size ?? from,
            tolerance: tolerance
        )
        return SnapshotCacheUse(entry: chosen.entry, otherSize: chosen.otherSize, target: target, resize: resize)
    }

    /// Stores the image as the window's image of its size. A third size
    /// replaces the least recently used one of the window.
    public mutating func store(
        _ id: WindowID, image: Image, frame: CGRect, pixels: Int, at now: TimeInterval,
        resolution: SnapshotResolution = .full, fill: ThemeColor? = nil
    ) {
        var list = entries[id] ?? []
        list.removeAll { snapshotSameSize($0.frame, frame, tolerance: 2) }
        while list.count >= snapshotSizesPerWindow, let oldest = list.indices.min(by: {
            (list[$0].lastUsed, list[$0].capturedAt) < (list[$1].lastUsed, list[$1].capturedAt)
        }) {
            list.remove(at: oldest)
        }
        list.append(SnapshotCacheEntry(
            image: image, frame: frame, capturedAt: now, lastUsed: now, pixels: pixels, resolution: resolution,
            fill: fill
        ))
        entries[id] = list
    }

    /// Mark the windows' newest images as just used (the LRU order).
    public mutating func touch(_ ids: some Sequence<WindowID>, at now: TimeInterval) {
        for id in ids {
            if let newest = entry(id) {
                touch(id, frame: newest.frame, at: now)
            }
        }
    }

    /// Mark the window's image of `frame`'s size as just used.
    public mutating func touch(_ id: WindowID, frame: CGRect, at now: TimeInterval) {
        guard var list = entries[id], let index = list.lastIndex(where: {
            snapshotSameSize($0.frame, frame, tolerance: 2)
        }) else {
            return
        }
        list[index].lastUsed = now
        entries[id] = list
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

    /// Until the total (SM-20: backdrops included, never evicted) is within
    /// `capPixels`. SM-25 order: secondary images of any window first (a size
    /// the window is not at now, `currentFrame`; without a current frame, any
    /// image but the newest: only an Alt+F back needs them), then SM-13:
    /// windows outside `protected` (the ones on screen and next to them)
    /// before any protected one, then least recently used first. SM-21: the
    /// primary image of a `pinned` window (the shown strips) is never
    /// evicted: the cap yields and the total may stay above it (pinned
    /// windows count as protected for the order). SM-22: within each class,
    /// a full-resolution image of a window outside `pinned` (a workspace
    /// that was shown and is hidden now) goes before any half-resolution
    /// image: coverage captures it again at half. Returns every evicted
    /// image's window and resolution, in eviction order.
    @discardableResult
    public mutating func enforce(
        capPixels: Int, protected: Set<WindowID> = [], pinned: Set<WindowID> = [],
        currentFrame: (WindowID) -> CGRect? = { _ in nil }
    ) -> [SnapshotEviction] {
        var total = totalPixels + backdropPixels
        guard total > capPixels else {
            return []
        }
        var candidates: [(
            id: WindowID, capturedAt: TimeInterval, lastUsed: TimeInterval, pixels: Int, secondary: Bool,
            protected: Bool, resolution: SnapshotResolution, overResolved: Bool
        )] = []
        for (id, list) in entries {
            let current = currentFrame(id)
            let newest = entry(id)?.capturedAt
            let isProtected = protected.contains(id) || pinned.contains(id)
            for item in list {
                let secondary = current.map { !snapshotSameSize(item.frame, $0, tolerance: 2) } ?? (item.capturedAt != newest)
                if pinned.contains(id), !secondary {
                    continue
                }
                candidates.append((
                    id, item.capturedAt, item.lastUsed, item.pixels, secondary, isProtected, item.resolution,
                    item.resolution == .full && !pinned.contains(id)
                ))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.secondary != rhs.secondary { return lhs.secondary }
            if lhs.protected != rhs.protected { return rhs.protected }
            if lhs.overResolved != rhs.overResolved { return lhs.overResolved }
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed < rhs.lastUsed }
            return lhs.id != rhs.id ? lhs.id < rhs.id : lhs.capturedAt < rhs.capturedAt
        }
        var evicted: [SnapshotEviction] = []
        for candidate in candidates where total > capPixels {
            guard var list = entries[candidate.id],
                  let index = list.firstIndex(where: { $0.capturedAt == candidate.capturedAt })
            else {
                continue
            }
            list.remove(at: index)
            entries[candidate.id] = list.isEmpty ? nil : list
            evicted.append(SnapshotEviction(id: candidate.id, resolution: candidate.resolution))
            total -= candidate.pixels
        }
        return evicted
    }

    public mutating func removeAll() {
        entries.removeAll()
        backdrops.removeAll()
    }

    // MARK: Backdrops (SM-09)

    public var backdropPixels: Int { backdrops.reduce(0) { $0 + $1.pixels } }

    public func backdrop(for displayFrame: CGRect) -> SnapshotBackdropEntry<Image>? {
        backdrops.first { $0.displayFrame == displayFrame }
    }

    public mutating func storeBackdrop(image: Image, displayFrame: CGRect, pixels: Int, at now: TimeInterval) {
        backdrops.removeAll { $0.displayFrame == displayFrame }
        backdrops.append(SnapshotBackdropEntry(image: image, displayFrame: displayFrame, capturedAt: now, pixels: pixels))
    }

    /// Drop the backdrops of displays that are gone. Returns the dropped frames.
    @discardableResult
    public mutating func retainBackdrops(onlyFrames keep: [CGRect]) -> [CGRect] {
        let dropped = backdrops.map(\.displayFrame).filter { !keep.contains($0) }
        backdrops.removeAll { !keep.contains($0.displayFrame) }
        return dropped
    }

    // MARK: SM-20 pruning and memory pressure

    /// Drops what no flight can use any more: any image older than `maxAge`
    /// when the window has no current frame, and the backdrops of displays not
    /// in `displayFrames`. A placed window keeps its images whatever their age
    /// (SM-24: the current size flies at any age; SM-25: the other size is the
    /// exact image when Alt+F toggles back; the cap evicts sizes a window is
    /// not at now first). Backdrops of shown displays always stay (a stale
    /// desktop beats a fallback).
    @discardableResult
    public mutating func prune(
        now: TimeInterval, currentFrame: (WindowID) -> CGRect?, displayFrames: [CGRect],
        maxAge: TimeInterval = snapshotMaxAge
    ) -> SnapshotPruneResult {
        var result = SnapshotPruneResult()
        var expired = 0
        for id in entries.keys.sorted() where currentFrame(id) == nil {
            let list = entries[id] ?? []
            let kept = list.filter { now - $0.capturedAt <= maxAge }
            expired += list.count - kept.count
            if kept.isEmpty {
                entries.removeValue(forKey: id)
                result.emptied.append(id)
            } else if kept.count != list.count {
                entries[id] = kept
            }
        }
        if expired > 0 {
            result.images[.age] = expired
        }
        let gone = retainBackdrops(onlyFrames: displayFrames).count
        if gone > 0 {
            result.images[.display] = gone
        }
        return result
    }

    /// Memory pressure. SM-21: a warning is not a purge: every image of a
    /// window in `shown` (the shown workspaces' strips) or `adjacent` (the
    /// workspaces next to them) stays; the other windows lose their images of
    /// another size than the current one and every image past `maxAge` (a
    /// stale image could still fly, SM-24, but a warning trades it for memory).
    /// Critical: only the `shown` windows' images of their current size
    /// stay. Both keep the backdrops of the shown displays
    /// (`displayFrames`) and drop the others. Returns the images freed,
    /// backdrops included.
    @discardableResult
    public mutating func relieve(
        _ level: SnapshotMemoryPressure, shown: Set<WindowID>, adjacent: Set<WindowID>,
        currentFrame: (WindowID) -> CGRect?, displayFrames: [CGRect], now: TimeInterval,
        maxAge: TimeInterval = snapshotMaxAge
    ) -> Int {
        var freed = 0
        for (id, list) in entries {
            let kept: [SnapshotCacheEntry<Image>]
            switch level {
            case .warning where shown.contains(id) || adjacent.contains(id):
                kept = list
            case .warning:
                let current = currentFrame(id)
                kept = list.filter { item in
                    now - item.capturedAt <= maxAge
                        && (current.map { snapshotSameSize(item.frame, $0, tolerance: 2) } ?? true)
                }
            case .critical:
                let current = shown.contains(id) ? currentFrame(id) : nil
                kept = current.map { frame in list.filter { snapshotSameSize($0.frame, frame, tolerance: 2) } } ?? []
            }
            freed += list.count - kept.count
            entries[id] = kept.isEmpty ? nil : kept
        }
        return freed + retainBackdrops(onlyFrames: displayFrames).count
    }

    /// Age of the oldest newest-image among `ids`, in milliseconds (0 for none).
    public func maxAgeMilliseconds(of ids: some Sequence<WindowID>, now: TimeInterval) -> Int {
        let ages = ids.compactMap { entry($0) }.map { now - $0.capturedAt }
        return Int(((ages.max() ?? 0) * 1000).rounded())
    }
}

// MARK: - SM-20 pruning and memory pressure

/// Why `SnapshotCache.prune` dropped an image.
public enum SnapshotPruneReason: String, CaseIterable, Sendable {
    /// Older than the max age, of a window without a current frame.
    case age
    /// The backdrop of a display that is gone.
    case display
}

public struct SnapshotPruneResult: Equatable, Sendable {
    /// Images dropped per reason (only reasons that dropped any).
    public var images: [SnapshotPruneReason: Int] = [:]
    /// Windows left without any image, in id order.
    public var emptied: [WindowID] = []

    public init() {}

    /// `snapshot cache pruned images=N reason=<age|display>`, one per
    /// reason that dropped any, in that order.
    public var logLines: [String] {
        SnapshotPruneReason.allCases.compactMap { reason in
            images[reason].map { "snapshot cache pruned images=\($0) reason=\(reason.rawValue)" }
        }
    }
}

/// The system memory pressure level the session relays to the cache.
public enum SnapshotMemoryPressure: String, Sendable {
    case warning, critical
}

/// `snapshot cache pressure level=<warning|critical> freed=N` (images).
public func snapshotPressureLogLine(level: SnapshotMemoryPressure, freed: Int) -> String {
    "snapshot cache pressure level=\(level.rawValue) freed=\(freed)"
}

/// SM-21: `snapshot cache cap exceeded by strip images=N`: the shown
/// strips' images alone are over the cap, which yields for them.
public func snapshotStripCapLogLine(images: Int) -> String {
    "snapshot cache cap exceeded by strip images=\(images)"
}

// MARK: - SM-11 off-screen windows and attributed misses

/// Points of a window that must show on a display for it to count as on
/// screen: a parked window keeps a 1 pt sliver.
public let snapshotOnScreenMinimum: CGFloat = 8

/// The window is parked or otherwise off screen: no display shows at least
/// `snapshotOnScreenMinimum` points of it in both directions.
public func snapshotFrameIsOffScreen(_ frame: CGRect, displays: [CGRect]) -> Bool {
    !displays.contains { display in
        let shown = display.intersection(frame)
        return !shown.isNull && shown.width >= snapshotOnScreenMinimum && shown.height >= snapshotOnScreenMinimum
    }
}

/// `snapshot miss id=P:E reason=<why> app=<name>` (no title).
public func snapshotMissLogLine(id: WindowID, reason: SnapshotMiss, app: String) -> String {
    "snapshot miss id=\(id.pid):\(id.elementID) reason=\(reason.rawValue) app=\(app)"
}

/// How often one window logs the same miss reason.
public let snapshotMissLogInterval: TimeInterval = 60

/// Once per window per reason per `snapshotMissLogInterval`.
public struct SnapshotMissLogThrottle {
    private struct Key: Hashable {
        let id: WindowID
        let reason: SnapshotMiss
    }

    private var logged: [Key: TimeInterval] = [:]

    public init() {}

    public mutating func shouldLog(_ id: WindowID, reason: SnapshotMiss, now: TimeInterval) -> Bool {
        let key = Key(id: id, reason: reason)
        if let last = logged[key], now - last < snapshotMissLogInterval {
            return false
        }
        if logged.count > 256 {
            logged = logged.filter { now - $0.value < snapshotMissLogInterval }
        }
        logged[key] = now
        return true
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

// MARK: - SM-09 selective refresh

/// SM-21: which windows of the shown strips (every managed, non-minimized
/// tiled window of a shown workspace, all columns) a settle run captures:
/// those marked dirty, and those without a usable image of their current
/// size (none at all, only another size, or one past `maxAge`). The soft
/// age is the refresh set's rule, not the strip's. Whether a window was
/// tried before does not matter; `excluded` (known blank/unmatchable
/// parked windows) never is. Strip order.
public func snapshotStripSelection<Image>(
    cache: SnapshotCache<Image>, strip: [(id: WindowID, frame: CGRect)],
    dirty: [WindowID: SnapshotCaptureReason], excluded: Set<WindowID>, now: TimeInterval,
    maxAge: TimeInterval = snapshotMaxAge, tolerance: CGFloat = 2
) -> [(id: WindowID, cause: SnapshotRefreshCause)] {
    strip.compactMap { item in
        guard !excluded.contains(item.id) else {
            return nil
        }
        if let reason = dirty[item.id] {
            return (item.id, .dirty(reason))
        }
        guard cache.entry(item.id) != nil else {
            return (item.id, .missing)
        }
        guard let entry = cache.entry(item.id, matching: item.frame, tolerance: tolerance) else {
            return (item.id, .sizeChanged)
        }
        if now - entry.capturedAt > maxAge {
            return (item.id, .stale)
        }
        // SM-22: captured while its workspace was hidden.
        return entry.resolution == .half ? (item.id, .halfResolution) : nil
    }
}

/// Why a wanted window is captured again.
public enum SnapshotRefreshCause: Equatable, Sendable {
    case missing
    case sizeChanged
    case dirty(SnapshotCaptureReason)
    /// Older than the soft age.
    case stale
    /// SM-22: a half-resolution image of a window that wants full.
    case halfResolution
}

/// Which of the wanted windows a refresh must capture: those without an
/// image, without one of their current size, marked dirty, or whose image
/// of that size is older than `softAge`. A
/// window that only moved keeps its image (layers fly from the current
/// frame). Wanted order. A missing image that was marked dirty (a new
/// window) reports the mark, so the run is logged with its reason. SM-22:
/// a window in `fullResolution` (a shown strip) whose image of its size is
/// half resolution is captured again; any other keeps it.
public func snapshotRefreshSelection<Image>(
    cache: SnapshotCache<Image>, wanted: [(id: WindowID, frame: CGRect)],
    dirty: [WindowID: SnapshotCaptureReason], now: TimeInterval,
    softAge: TimeInterval = snapshotSoftAge, tolerance: CGFloat = 2, fullResolution: Set<WindowID> = []
) -> [(id: WindowID, cause: SnapshotRefreshCause)] {
    wanted.compactMap { item in
        guard cache.entry(item.id) != nil else {
            return (item.id, dirty[item.id].map { .dirty($0) } ?? .missing)
        }
        // SM-11: an image of either kept size counts.
        guard let entry = cache.entry(item.id, matching: item.frame, tolerance: tolerance) else {
            return (item.id, .sizeChanged)
        }
        if let reason = dirty[item.id] {
            return (item.id, .dirty(reason))
        }
        if entry.resolution == .half, fullResolution.contains(item.id) {
            return (item.id, .halfResolution)
        }
        if now - entry.capturedAt > softAge {
            return (item.id, .stale)
        }
        return nil
    }
}

/// The reason logged for one capture run: the most specific cause wins
/// (new > size > focus > typing); missing or stale images are the plain
/// settle refresh; a run with only a backdrop is `backdrop`.
public func snapshotRefreshReason(causes: [SnapshotRefreshCause], backdrop: Bool) -> SnapshotCaptureReason {
    func rank(_ cause: SnapshotRefreshCause) -> Int {
        switch cause {
        case .dirty(.new): return 5
        case .sizeChanged: return 4
        case .dirty(.focus): return 3
        case .dirty(.typing): return 2
        case .dirty, .missing, .stale, .halfResolution: return 1
        }
    }
    switch causes.map(rank).max() {
    case 5?: return .new
    case 4?: return .size
    case 3?: return .focus
    case 2?: return .typing
    case 1?: return .settle
    default: return backdrop ? .backdrop : .settle
    }
}

// MARK: - SM-09 blank guard

/// A capture that shows nothing: every sample transparent, or every opaque
/// sample the same colour (an unpainted or stale window). Samples are
/// packed RGBA (alpha in the low byte), taken on a grid that includes the
/// edges so a title bar or border counts as content. No samples: not blank
/// (the image is kept rather than dropped on a sampling failure).
public func snapshotLooksBlank(samples: [UInt32]) -> Bool {
    guard !samples.isEmpty else {
        return false
    }
    let opaque = samples.filter { $0 & 0xFF != 0 }
    guard let first = opaque.first else {
        return true
    }
    return opaque.allSatisfy { $0 == first }
}

/// SM-10: the sparse grid alone mistakes a sparse window (a terminal with
/// one prompt line, an empty editor) for an unpainted one. A blank verdict
/// on `samples` is confirmed by `dense` (a coarse scan of the whole image,
/// ~64x64 nearest-neighbour samples, taken only when needed); the capture
/// is blank only when both agree. The trade-off left: a window whose only
/// content is smaller than the dense step (one cursor) still reads blank.
public func snapshotLooksBlank(samples: [UInt32], dense: () -> [UInt32]) -> Bool {
    snapshotLooksBlank(samples: samples) && snapshotLooksBlank(samples: dense())
}

// MARK: - SM-09 typing signal

/// The hotkey tap sees every key-down on main; the session hears about
/// typing at most this often (one dispatch, one timestamp).
public let snapshotTypingHopInterval: TimeInterval = 0.5

public func snapshotTypingHopDue(now: TimeInterval, lastHop: TimeInterval?, interval: TimeInterval) -> Bool {
    lastHop.map { now - $0 >= interval } ?? true
}

/// PF-V: quiet time after the last typing hop before the typed-in window is
/// captured. Longer than two hops, so steady typing (a hop every ~0.5 s)
/// keeps pushing it back and only a real pause captures (the old 0.6 s was
/// shorter than the gap between hops: a capture every second or two).
public let snapshotTypingQuiet: TimeInterval = 1.5
/// PF-V: a typing capture never comes sooner than this after the window's
/// last image (typing all day captured several times a minute). Only the
/// outgoing window of a flight right after typing can show content up to
/// this old, for the length of the slide.
public let snapshotTypingFloor: TimeInterval = 5

/// PF-V: how long a typing capture waits from now: the pause, or longer
/// while the window's newest image (`capturedAt`) is younger than the floor.
public func snapshotTypingCaptureDelay(capturedAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
    guard let capturedAt else {
        return snapshotTypingQuiet
    }
    return max(snapshotTypingQuiet, capturedAt + snapshotTypingFloor - now)
}

// MARK: - SM-09 backdrop staleness

/// An on-screen window the backdrop shows, rounded to whole points so a
/// WindowServer re-read without any change compares equal.
public struct ServerWindowKey: Hashable, Sendable {
    public let pid: pid_t
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(pid: pid_t, x: Int, y: Int, width: Int, height: Int) {
        self.pid = pid
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The on-screen windows Gio does not manage (other apps' palettes and
/// unmanaged windows, desktop widgets): what the backdrop shows besides the
/// wallpaper. Gio's own windows and every managed window (matched by pid
/// and a frame within the render tolerance) are left out, so Gio moving its
/// own layout never changes the fingerprint; anything else appearing,
/// closing or moving does, and the backdrop is captured again. PF-AJ: so is
/// every window that shows no more than a parking sliver on any of
/// `displays` (it is not in the picture; parked windows macOS clamped or
/// whose app kept its own size used to change it on every re-park).
public func unmanagedWindowFingerprint(
    server: [ServerWindow], managed: [WindowID: CGRect], ownPid: pid_t, displays: [CGRect]
) -> Set<ServerWindowKey> {
    var byPid: [pid_t: [CGRect]] = [:]
    for (id, frame) in managed {
        byPid[id.pid, default: []].append(frame)
    }
    var result: Set<ServerWindowKey> = []
    for window in server where window.pid != ownPid && showsMoreThanASliver(window.bounds, on: displays) {
        if let frames = byPid[window.pid], frames.contains(where: { near($0, window.bounds) }) {
            continue
        }
        result.insert(ServerWindowKey(
            pid: window.pid, x: Int(window.bounds.origin.x.rounded()), y: Int(window.bounds.origin.y.rounded()),
            width: Int(window.bounds.width.rounded()), height: Int(window.bounds.height.rounded())
        ))
    }
    return result
}

private func showsMoreThanASliver(_ frame: CGRect, on displays: [CGRect]) -> Bool {
    displays.contains { display in
        let inside = frame.intersection(display)
        return !inside.isNull && inside.width > parkingSliver * 2 && inside.height > parkingSliver * 2
    }
}

/// Whether a managed window is cut out of the backdrop: only windows that
/// can be flight items (tiled, on screen). Floating windows never enter a
/// flight (`tilingWorkspace` drops them from the strip), so they would be
/// missing from both the backdrop and the layers; the backdrop keeps them.
public func backdropExcludesWindow(mode: WindowMode, isMinimized: Bool) -> Bool {
    !isMinimized && mode != .floating
}
