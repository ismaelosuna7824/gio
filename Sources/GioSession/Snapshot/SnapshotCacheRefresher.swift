import CoreGraphics
import Foundation
import GioCore
import GioMacOS

/// One captured window image and the frame it was captured at.
public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let frame: CGRect

    public init(image: CGImage, frame: CGRect) {
        self.image = image
        self.frame = frame
    }
}

/// SM-04: the pre-captured window images the overlay flies, refreshed once
/// after each settle (debounced one-shot, no periodic timer), coalesced
/// while a capture runs, capped and pruned to live windows; plus the SM-02b
/// shareable-content prefetch. Session queue only; the capture itself runs
/// off the queue and its completion hops back.
public final class SnapshotCacheRefresher: @unchecked Sendable {
    public struct Context {
        public var session: () -> CommandSession
        public var displays: () -> [DisplayState]
        public var physicalFrame: (WindowID) -> CGRect?
        public var isShuttingDown: () -> Bool
        public var isFlightActive: () -> Bool
        public var isMotionActive: () -> Bool
        /// The snapshot renderer is configured, permitted and supported.
        public var rendererAvailable: () -> Bool
        /// Screens as the capture needs them and the primary display height
        /// (read on main, handed over under a lock).
        public var captureScreens: () -> (screens: [SnapshotDisplay], primaryHeight: CGFloat)
        /// Captures off the session queue; `completion` may run on any thread.
        public var capture: (SnapshotCaptureRequest, @escaping @Sendable ([WindowID: CapturedImage]) -> Void) -> Void
        /// Refreshes the shareable content off the queue; `completion` on any thread.
        public var prefetch: (Set<WindowID>, @escaping @Sendable () -> Void) -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            session: @escaping () -> CommandSession, displays: @escaping () -> [DisplayState],
            physicalFrame: @escaping (WindowID) -> CGRect?, isShuttingDown: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isMotionActive: @escaping () -> Bool,
            rendererAvailable: @escaping () -> Bool,
            captureScreens: @escaping () -> (screens: [SnapshotDisplay], primaryHeight: CGFloat),
            capture: @escaping (SnapshotCaptureRequest, @escaping @Sendable ([WindowID: CapturedImage]) -> Void) -> Void,
            prefetch: @escaping (Set<WindowID>, @escaping @Sendable () -> Void) -> Void,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.session = session
            self.displays = displays
            self.physicalFrame = physicalFrame
            self.isShuttingDown = isShuttingDown
            self.isFlightActive = isFlightActive
            self.isMotionActive = isMotionActive
            self.rendererAvailable = rendererAvailable
            self.captureScreens = captureScreens
            self.capture = capture
            self.prefetch = prefetch
            self.log = log
            self.now = now
        }
    }

    /// Longest refresh set captured after a settle.
    public static let maxWindows = 12

    private let context: Context
    private let scheduler: SessionScheduler
    public private(set) var cache = SnapshotCache<CGImage>()
    private var token = 0
    private var busy = false
    private var again = false
    /// SM-02b: managed set the shareable content was last prefetched for,
    /// and whether a prefetch is running.
    private var lastPrefetchedWindows: Set<WindowID>?
    private var prefetchInFlight = false

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    /// Snapshot rendering is in force: configured, permission granted,
    /// macOS 14+. Otherwise the cache is dropped (its memory is released and
    /// an overlay is never shown without fresh images).
    public func rendererUsable() -> Bool {
        let usable = context.rendererAvailable()
        if !usable, cache.count > 0 {
            cache.removeAll()
            context.log(.debug, "snapshot cache cleared renderer=ax")
        }
        return usable
    }

    /// Images mark as just used (the LRU order).
    public func touch(_ ids: some Sequence<WindowID>, at now: TimeInterval) {
        cache.touch(ids, at: now)
    }

    public func removeAll() {
        cache.removeAll()
    }

    /// Purged windows lose their image.
    public func evict(_ ids: some Sequence<WindowID>) {
        cache.evict(ids)
    }

    /// One-shot, debounced: ~300 ms after a settle, capture the visible
    /// windows and their neighbours in the background. No periodic timer.
    public func schedule(delay: TimeInterval = 0.3) {
        guard !context.isShuttingDown(), rendererUsable() else {
            return
        }
        token += 1
        let token = token
        scheduler.asyncAfter(delay) { [weak self] in
            self?.run(token: token)
        }
    }

    /// SM-02b: refreshes the ScreenCaptureKit content in the background at
    /// session start and whenever the managed window set changes, so motion
    /// requests do not pay the fetch inside their budget.
    public func prefetchIfNeeded(permissionGranted: Bool) {
        let managed = Set(context.session().registry.managedWindows().map(\.id))
        guard shouldPrefetchShareableContent(
            managed: managed, lastPrefetched: lastPrefetchedWindows,
            permissionGranted: permissionGranted, inFlight: prefetchInFlight
        ) else {
            return
        }
        lastPrefetchedWindows = managed
        prefetchInFlight = true
        context.prefetch(managed) { [weak self] in
            self?.scheduler.async { [weak self] in
                self?.prefetchInFlight = false
            }
        }
    }

    /// Windows to keep cached and where they are now: visible ones, the
    /// columns next to the viewport, and the focused window of the adjacent
    /// workspaces of each display (at most 12).
    public func refreshSet() -> [(id: WindowID, frame: CGRect)] {
        let session = context.session()
        var ordered: [WindowID] = []
        for display in context.displays() {
            guard let workspace = session.manager.workspace(id: display.workspace) else {
                continue
            }
            let columns = workspace.columns.map(\.windows)
            let visible = Set(columns.joined().filter { id in
                context.physicalFrame(id).map {
                    overlayDisplayIndex(from: $0, to: $0, displays: [display.frame]) != nil
                } ?? false
            })
            var extras: [WindowID] = []
            let stack = session.manager.stack(on: display.id)
            if let index = stack.firstIndex(where: { $0.id == display.workspace }) {
                for neighbour in [index - 1, index + 1] where stack.indices.contains(neighbour) {
                    if let focused = stack[neighbour].focusedWindow {
                        extras.append(focused)
                    }
                }
            }
            ordered += snapshotCaptureSet(columns: columns, visible: visible, extras: extras)
        }
        var seen: Set<WindowID> = []
        var result: [(id: WindowID, frame: CGRect)] = []
        for id in ordered where seen.insert(id).inserted {
            guard let window = session.registry.find(id), !window.isMinimized,
                  let frame = context.physicalFrame(id)
            else {
                continue
            }
            result.append((id, frame))
            if result.count == Self.maxWindows {
                break
            }
        }
        return result
    }

    private func run(token: Int) {
        guard token == self.token, !context.isShuttingDown(), !context.isFlightActive(),
              !context.isMotionActive(), rendererUsable()
        else {
            return
        }
        guard !busy else {
            again = true
            return
        }
        let wanted = refreshSet()
        guard !wanted.isEmpty else {
            return
        }
        let (screens, primary) = context.captureScreens()
        let request = SnapshotCaptureRequest(
            windows: Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0.frame) }),
            displays: screens, primaryDisplayHeight: primary, includeBackdrop: false,
            budgetMilliseconds: 1500, logLevel: .debug
        )
        busy = true
        context.capture(request) { [weak self] images in
            self?.scheduler.async { [weak self] in
                self?.finish(images)
            }
        }
    }

    private func finish(_ images: [WindowID: CapturedImage]) {
        busy = false
        guard !context.isShuttingDown(), rendererUsable() else {
            return
        }
        let now = context.now()
        for (id, snapshot) in images {
            cache.store(
                id, image: snapshot.image, frame: snapshot.frame,
                pixels: snapshot.image.width * snapshot.image.height, at: now
            )
        }
        // Gone or minimized windows lose their image; the rest stays under the cap.
        let live = Set(context.session().registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        cache.retain(only: live)
        let displayPixels = context.captureScreens().screens.map {
            Int($0.frame.width * $0.scale) * Int($0.frame.height * $0.scale)
        }.max() ?? 0
        let evicted = cache.enforce(capPixels: snapshotCacheCapPixels(displayPixels: displayPixels))
        context.log(
            .debug,
            "snapshot cache entries=\(cache.count) pixels=\(cache.totalPixels) evicted=\(evicted.count)"
        )
        if again {
            again = false
            schedule(delay: 0.05)
        }
    }
}
