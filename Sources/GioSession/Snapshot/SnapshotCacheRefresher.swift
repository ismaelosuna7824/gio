import CoreGraphics
import Foundation
import GioCore
import GioMacOS

/// One captured window image, the frame it was captured at and (SM-27,
/// SM-30) its fill (`snapshotContentFill`).
public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let frame: CGRect
    public let fill: ThemeColor?

    public init(image: CGImage, frame: CGRect, fill: ThemeColor? = nil) {
        self.image = image
        self.frame = frame
        self.fill = fill
    }
}

/// SM-09: one display backdrop (desktop, icons, unmanaged windows; no
/// managed window) keyed by the display frame it was captured for.
public struct CapturedBackdropImage: @unchecked Sendable {
    public let image: CGImage
    public let displayFrame: CGRect

    public init(image: CGImage, displayFrame: CGRect) {
        self.image = image
        self.displayFrame = displayFrame
    }
}

/// What one capture run delivered, and why each window it did not deliver missed.
public struct SnapshotCaptureOutcome: @unchecked Sendable {
    public var images: [WindowID: CapturedImage]
    public var backdrops: [CapturedBackdropImage]
    public var misses: [WindowID: SnapshotMiss]

    public init(
        images: [WindowID: CapturedImage] = [:], backdrops: [CapturedBackdropImage] = [],
        misses: [WindowID: SnapshotMiss] = [:]
    ) {
        self.images = images
        self.backdrops = backdrops
        self.misses = misses
    }
}

/// SM-04/SM-09/SM-11: the pre-captured window images (up to two sizes per
/// window) and per-display backdrops the overlay flies. Refreshed by
/// one-shot debounced runs (never a periodic timer): after each settle, and
/// on dirty signals (typing in the focused window, a window focused for
/// 3 s, a new window). A run captures only what is missing, resized, dirty
/// or older than the soft age, never the whole set; the backdrop only when
/// missing, past its max age or when the unmanaged on-screen windows
/// changed. SM-11 coverage: a settle run also captures the windows of every
/// workspace that have no image yet, at most `maxWindows` per run, staged
/// until none is missing; each such window is tried once until it
/// registers, moves workspace or shows again. A window that misses while
/// parked is not retried before it is visible. SM-13: under the cap the
/// images of windows away from the screen go first; once an eviction ran,
/// coverage stops (logged once) until a window leaves the cache. SM-20:
/// every settle run first prunes the images no flight can use (a window
/// without a frame past the max age, backdrops of gone displays; a placed
/// window keeps its images: SM-24, the current size at any age; SM-25, the
/// other size). A hidden-workspace window whose image is missing or stale is
/// captured again when its workspace becomes adjacent to a shown one (the
/// visible and adjacent windows keep their freshness rules). System memory pressure
/// (`noteMemoryPressure`, event-driven) drops more. SM-21: the shown strips
/// (every tiled, non-minimized window of every shown workspace, all
/// columns) are always covered: a settle run captures each strip window
/// without a fresh image of its current size, tried or not (staged, each
/// window once per settle), pressure never drops their current-size
/// images, the cap never evicts them, and pressure back to normal starts
/// one recovery run. SM-22: the shown strips are captured at full
/// resolution, every other window at half (a hidden workspace is seen only
/// during a switch slide); a half image flies like any other and a shown
/// strip window with one is captured again at full by the next settle. The
/// cap is the smaller of eight display-fulls and 3 % of the RAM (logged
/// once); it evicts the full images of hidden windows first, coverage
/// brings those back at half, and coverage stops only when a half image
/// had to go. SM-31: a window macOS no longer draws (its AX element
/// vanished, or a capture found no WindowServer window for it on screen)
/// loses its images at once and stays out of every flight
/// (`undrawnWindows`) until a capture matches it again; FI-08's unknown
/// windows keep theirs. Session queue only; the capture itself runs off the
/// queue and its completion hops back.
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
        /// NA-03: the close ghost is on (and Screen Recording granted): keep a
        /// light cache of the windows in view even with the ax renderer.
        public var ghostCacheWanted: () -> Bool
        /// Screens as the capture needs them and the primary display height
        /// (read on main, handed over under a lock).
        public var captureScreens: () -> (screens: [SnapshotDisplay], primaryHeight: CGFloat)
        /// Captures off the session queue; `completion` may run on any thread.
        public var capture: (SnapshotCaptureRequest, @escaping @Sendable (SnapshotCaptureOutcome) -> Void) -> Void
        /// Refreshes the shareable content off the queue; `completion` on any thread.
        public var prefetch: (Set<WindowID>, @escaping @Sendable () -> Void) -> Void
        /// SM-09: on-screen WindowServer windows (one query), for the
        /// backdrop staleness check; empty when unavailable.
        public var serverWindows: () -> [ServerWindow]
        public var ownPid: pid_t
        public var log: (LogLevel, String) -> Void
        /// SM-11: app name for the miss line (never a title).
        public var appName: (pid_t) -> String
        /// SM-22: bytes of RAM, read once by the host; bounds the cap.
        public var physicalMemory: UInt64
        public var now: () -> TimeInterval

        public init(
            session: @escaping () -> CommandSession, displays: @escaping () -> [DisplayState],
            physicalFrame: @escaping (WindowID) -> CGRect?, isShuttingDown: @escaping () -> Bool,
            isFlightActive: @escaping () -> Bool, isMotionActive: @escaping () -> Bool,
            rendererAvailable: @escaping () -> Bool,
            ghostCacheWanted: @escaping () -> Bool = { false },
            captureScreens: @escaping () -> (screens: [SnapshotDisplay], primaryHeight: CGFloat),
            capture: @escaping (SnapshotCaptureRequest, @escaping @Sendable (SnapshotCaptureOutcome) -> Void) -> Void,
            prefetch: @escaping (Set<WindowID>, @escaping @Sendable () -> Void) -> Void,
            serverWindows: @escaping () -> [ServerWindow] = { [] },
            ownPid: pid_t = 0,
            log: @escaping (LogLevel, String) -> Void,
            appName: @escaping (pid_t) -> String = { _ in "?" },
            physicalMemory: UInt64,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.session = session
            self.displays = displays
            self.physicalFrame = physicalFrame
            self.isShuttingDown = isShuttingDown
            self.isFlightActive = isFlightActive
            self.isMotionActive = isMotionActive
            self.rendererAvailable = rendererAvailable
            self.ghostCacheWanted = ghostCacheWanted
            self.captureScreens = captureScreens
            self.capture = capture
            self.prefetch = prefetch
            self.serverWindows = serverWindows
            self.ownPid = ownPid
            self.log = log
            self.appName = appName
            self.physicalMemory = physicalMemory
            self.now = now
        }
    }

    /// Longest refresh set captured after a settle, and most windows one
    /// run captures (SM-11: coverage fills up to it).
    public static let maxWindows = 12
    /// Debounce of a dirty signal (typing, focus, new window).
    public static let dirtyDelay: TimeInterval = 0.6
    /// SM-11: a window focused this long is likely used; its image is
    /// captured again (a focus change alone changes no content).
    public static let focusDwell: TimeInterval = 3
    /// SM-11: pause between two coverage stages.
    public static let stageDelay: TimeInterval = 0.3

    private let context: Context
    private let scheduler: SessionScheduler
    public private(set) var cache = SnapshotCache<CGImage>()
    private var token = 0
    private var busy = false
    /// A run was requested while one was busy; `againFull` when any of
    /// those was a settle refresh.
    private var again = false
    private var againFull = false
    /// The pending run is a settle refresh (whole wanted set considered);
    /// otherwise only the dirty windows.
    private var pendingFull = false
    /// SM-09: windows whose image changed since it was captured, by reason.
    private(set) var dirty: [WindowID: SnapshotCaptureReason] = [:]
    private var backdropDirty = false
    /// SM-09: unmanaged on-screen windows as of the last backdrop decision.
    private var unmanagedFingerprint: Set<ServerWindowKey>?
    /// SM-09: the focused window the last `noteFocus` saw.
    private var lastFocused: WindowID?
    /// SM-11: the pending focus-dwell check; a newer focus cancels it.
    private var focusToken = 0
    /// SM-11: windows a request already asked for since they registered,
    /// moved workspace or showed again: coverage does not ask twice.
    private var tried: Set<WindowID> = []
    /// SM-11: windows that missed while parked or off screen, retried only
    /// once they are visible (their previous image, if any, stays).
    private var parkedMisses: Set<WindowID> = []
    /// SM-31: windows macOS does not draw (vanished, or `undrawn` by a
    /// capture): no image, left out of every flight until a capture
    /// matches them again.
    public private(set) var undrawnWindows: Set<WindowID> = []
    /// SM-11: the workspace each covered window was last seen on.
    private var workspaceOf: [WindowID: WorkspaceID] = [:]
    /// SM-20: the shown workspaces and those next to them in each display's
    /// stack, as of the last run: a workspace that enters this set has its
    /// windows tried again by coverage (pruned hidden images come back).
    private var nearWorkspaces: Set<WorkspaceID> = []
    /// SM-13: the cap could not hold the coverage images (an eviction ran):
    /// no new coverage until a window leaves the cache.
    private var coverageStopped = false
    /// SM-21: strip windows already asked for since the last settle: a
    /// coverage stage continues only while some strip window lacking an
    /// image is not in it, and a stage does not ask one twice (a window
    /// that keeps missing waits for the next settle, no stage loop).
    private var stripPass: Set<WindowID> = []
    /// SM-21: a warning or critical event came and normal did not yet.
    private var underPressure = false
    /// SM-21: the strip alone exceeds the cap; logged once until it fits.
    private var stripCapLogged = false
    /// SM-22: the cap last logged (once at start; again only if the
    /// displays change it).
    private var loggedCapPixels: Int?
    private var missThrottle = SnapshotMissLogThrottle()
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
    /// an overlay is never shown without fresh images), unless the close
    /// ghost still wants it (NA-03).
    public func rendererUsable() -> Bool {
        let usable = context.rendererAvailable()
        if !usable, cache.count > 0 || cache.backdropPixels > 0, !context.ghostCacheWanted() {
            cache.removeAll()
            context.log(.debug, "snapshot cache cleared renderer=ax")
        }
        return usable
    }

    /// Someone uses the images: the overlay renderer or the close ghost.
    public func cacheWanted() -> Bool {
        context.rendererAvailable() || context.ghostCacheWanted()
    }

    public func removeAll() {
        cache.removeAll()
        coverageStopped = false
        dirty.removeAll()
        tried.removeAll()
        parkedMisses.removeAll()
        undrawnWindows.removeAll()
        workspaceOf.removeAll()
        nearWorkspaces.removeAll()
        stripPass.removeAll()
        stripCapLogged = false
        unmanagedFingerprint = nil
    }

    /// Purged windows lose their image.
    public func evict(_ ids: some Sequence<WindowID>) {
        let ids = Array(ids)
        cache.evict(ids)
        coverageStopped = false
        for id in ids {
            dirty.removeValue(forKey: id)
            tried.remove(id)
            parkedMisses.remove(id)
            undrawnWindows.remove(id)
            workspaceOf.removeValue(forKey: id)
        }
    }

    /// SM-31: the reconciler found these windows' AX elements invalid. They
    /// stay registered until a scan proves them gone (absence is not
    /// death), but their images go now and they stay out of every flight
    /// until a capture matches them again.
    public func noteVanished(_ ids: [WindowID]) {
        for id in ids {
            markUndrawn(id, reason: .vanished)
        }
    }

    /// SM-31: one debug line per window becoming undrawn, not per report.
    private func markUndrawn(_ id: WindowID, reason: SnapshotEvictReason) {
        guard undrawnWindows.insert(id).inserted else {
            return
        }
        cache.evict([id])
        dirty.removeValue(forKey: id)
        coverageStopped = false
        context.log(.debug, snapshotEvictLine(id: id, reason: reason))
    }

    // MARK: Flight images (SM-11, read by the flight controller)

    /// The image a flight from `startFrame` to `targetFrame` would use at
    /// `now` (see `SnapshotCache.usableEntry`): the one of the start size, or
    /// a fresh one of the other size, and (SM-27) the one of the target size
    /// to show instead (SM-32). Nil start: any image within the max age. A lookup
    /// only; SM-13: the flight looks each window up once and flies exactly
    /// that image (`flies`).
    public func flightImage(
        _ id: WindowID, startFrame: CGRect?, targetFrame: CGRect? = nil, at now: TimeInterval
    ) -> SnapshotCacheUse<CGImage>? {
        cache.usableEntry(id, startFrame: startFrame, targetFrame: targetFrame, now: now)
    }

    /// The chosen images fly: their sizes are marked used (the LRU order).
    /// SM-27: a layer that is not a pure move logs how it resizes without
    /// stretching (debug).
    public func flies(_ id: WindowID, _ use: SnapshotCacheUse<CGImage>, at now: TimeInterval) {
        cache.touch(id, frame: use.entry.frame, at: now)
        if let target = use.target {
            cache.touch(id, frame: target.frame, at: now)
        }
        if let mode = use.resize {
            logResize(id, mode)
        }
    }

    /// SM-27: a flying layer is retargeted from `from` to `to`: the face of
    /// `to`'s size it shows (the one it already shows when the size
    /// stays), nil when none is cached (the overlay then shows its closest
    /// face). A new size is logged: `swap` with a face,
    /// otherwise `fill`/`crop` against the layer's start `image` size.
    public func retargetFace(
        _ id: WindowID, image: CGSize, from: CGRect, to: CGRect, at now: TimeInterval
    ) -> SnapshotFace<CGImage>? {
        let entry = cache.entry(id, matching: to)
        if let entry {
            cache.touch(id, frame: entry.frame, at: now)
        }
        let resized = abs(from.width - to.width) > 2 || abs(from.height - to.height) > 2
        if resized,
           let mode = entry != nil ? .swap : snapshotResizeMode(image: image, target: nil, from: from.size, to: to.size) {
            logResize(id, mode)
        }
        return entry?.face
    }

    /// SM-30: a resized window captured again at its target size during
    /// the flight (full resolution): kept as its image of that size, so the
    /// next flight to it is not tens of seconds stale and the settle run
    /// does not capture it again.
    public func storeFresh(_ id: WindowID, _ captured: CapturedImage) {
        cache.store(
            id, image: captured.image, frame: captured.frame, pixels: captured.image.width * captured.image.height,
            at: context.now(), resolution: .full, fill: captured.fill
        )
        dirty.removeValue(forKey: id)
        undrawnWindows.remove(id)
    }

    private func logResize(_ id: WindowID, _ mode: SnapshotResizeMode) {
        context.log(.debug, "snapshot resize id=\(id.pid):\(id.elementID) mode=\(mode.rawValue)")
    }

    // MARK: Backdrop (SM-09, read by the flight controller)

    /// The backdrop for the display with this frame (`DisplayState.frame`),
    /// nil until one was captured. Age never makes it unusable: a stale
    /// desktop under the flight beats an AX fallback, and the settle run
    /// re-captures it past `snapshotBackdropMaxAge` or when the unmanaged
    /// windows changed.
    public func backdrop(for displayFrame: CGRect) -> CGImage? {
        cache.backdrop(for: displayFrame)?.image
    }

    public func backdropAge(for displayFrame: CGRect) -> TimeInterval? {
        cache.backdrop(for: displayFrame).map { context.now() - $0.capturedAt }
    }

    /// Display parameters or the Space changed: the backdrop shows
    /// something else now.
    public func markBackdropDirty() {
        backdropDirty = true
    }

    // MARK: Dirty signals (SM-09)

    /// The user typed into the focused window (coalesced by the caller to a
    /// few hops per second): its image changes while nothing moves. PF-V:
    /// captured after a pause, never sooner than the floor after its last
    /// image (`snapshotTypingCaptureDelay`).
    public func noteTyping() {
        guard let focused = context.session().manager.currentWorkspace().focusedWindow else {
            return
        }
        let delay = snapshotTypingCaptureDelay(capturedAt: cache.entry(focused)?.capturedAt, now: context.now())
        markDirty([focused], reason: .typing, delay: delay)
    }

    /// The focus is published. SM-11: a focus change alone changes no
    /// content worth a capture (Alt+H/L re-captured 2-4 windows per press);
    /// a window still focused `focusDwell` later is likely in use and
    /// becomes dirty once. One-shot check, cancelled by the next change.
    public func noteFocus(_ focused: WindowID?) {
        guard focused != lastFocused else {
            return
        }
        lastFocused = focused
        focusToken += 1
        guard let focused, !context.isShuttingDown(), context.rendererAvailable() else {
            return
        }
        let token = focusToken
        scheduler.asyncAfter(Self.focusDwell) { [weak self] in
            guard let self, token == focusToken, lastFocused == focused else {
                return
            }
            markDirty([focused], reason: .focus)
        }
    }

    /// A window was registered: capture it after its first write, wherever
    /// it lands (SM-11: coverage asks for it again).
    public func noteRegistered(_ id: WindowID) {
        tried.remove(id)
        parkedMisses.remove(id)
        undrawnWindows.remove(id)
        markDirty([id], reason: .new)
    }

    /// Dirty signals serve the overlay only; the close ghost (NA-03) lives
    /// with the settle refresh.
    /// SM-11: a window deferred as a parked miss is not marked again.
    private func markDirty(_ ids: [WindowID], reason: SnapshotCaptureReason, delay: TimeInterval = dirtyDelay) {
        let ids = ids.filter { !parkedMisses.contains($0) }
        guard !ids.isEmpty, !context.isShuttingDown(), context.rendererAvailable() else {
            return
        }
        for id in ids where dirty[id].map({ Self.rank($0) < Self.rank(reason) }) ?? true {
            dirty[id] = reason
        }
        scheduleRun(delay: delay, full: false)
    }

    /// More specific reasons replace less specific ones on the same window.
    private static func rank(_ reason: SnapshotCaptureReason) -> Int {
        switch reason {
        case .new: return 4
        case .size: return 3
        case .focus: return 2
        case .typing: return 1
        case .settle, .backdrop, .measure, .overview: return 0
        }
    }

    // MARK: Scheduling

    /// One-shot, debounced: ~300 ms after a settle, consider the visible
    /// windows and their neighbours (and the backdrop) in the background.
    /// No periodic timer.
    /// SM-21: each settle starts a new strip pass.
    public func schedule(delay: TimeInterval = 0.3) {
        stripPass.removeAll()
        scheduleRun(delay: delay, full: true)
    }

    private func scheduleRun(delay: TimeInterval, full: Bool) {
        guard !context.isShuttingDown(), cacheWanted() else {
            return
        }
        pendingFull = pendingFull || full
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
    /// workspaces of each display (at most 12). For the close ghost alone
    /// (ax renderer), only the windows in view.
    public func refreshSet() -> [(id: WindowID, frame: CGRect)] {
        let session = context.session()
        let ghostOnly = !context.rendererAvailable()
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
            if ghostOnly {
                ordered += columns.joined().filter { visible.contains($0) }
                continue
            }
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

    /// SM-21: the shown strips, every tiled, non-minimized window of each
    /// display's shown workspace (all columns, column order) with its
    /// frame, and every window of the workspaces next to them in each
    /// display's stack (`adjacent`, what a warning never touches).
    func stripPlan() -> (strip: [(id: WindowID, frame: CGRect)], adjacent: Set<WindowID>) {
        let session = context.session()
        var strip: [(id: WindowID, frame: CGRect)] = []
        var seen: Set<WindowID> = []
        var adjacent: Set<WindowID> = []
        for display in context.displays() {
            guard let workspace = session.manager.workspace(id: display.workspace) else {
                continue
            }
            for id in workspace.columns.flatMap(\.windows) where seen.insert(id).inserted {
                guard let window = session.registry.find(id),
                      backdropExcludesWindow(mode: window.mode, isMinimized: window.isMinimized),
                      let frame = context.physicalFrame(id)
                else {
                    continue
                }
                strip.append((id, frame))
            }
            let stack = session.manager.stack(on: display.id)
            if let index = stack.firstIndex(where: { $0.id == display.workspace }) {
                for neighbour in [index - 1, index + 1] where stack.indices.contains(neighbour) {
                    adjacent.formUnion(stack[neighbour].columns.flatMap(\.windows))
                }
            }
        }
        return (strip, adjacent)
    }

    /// The strip coverage cares about: none for the close ghost alone.
    private func coverageStrip() -> [(id: WindowID, frame: CGRect)] {
        context.rendererAvailable() ? stripPlan().strip : []
    }

    /// SM-11: every tiled, non-minimized window of every workspace of every
    /// stack with its frame and workspace, display by display, the
    /// workspaces nearest the active one first. Empty for the close ghost
    /// alone (it only needs the windows in view).
    func coverageSet() -> [(id: WindowID, frame: CGRect, workspace: WorkspaceID)] {
        guard context.rendererAvailable() else {
            return []
        }
        let session = context.session()
        var seen: Set<WindowID> = []
        var result: [(id: WindowID, frame: CGRect, workspace: WorkspaceID)] = []
        for display in session.manager.displayIDs {
            let stack = session.manager.stack(on: display)
            let active = stack.firstIndex { $0.id == session.manager.activeID(on: display) } ?? 0
            let order = stack.indices.sorted { (abs($0 - active), $0) < (abs($1 - active), $1) }
            for index in order {
                for id in stack[index].columns.flatMap(\.windows) where seen.insert(id).inserted {
                    guard let window = session.registry.find(id),
                          backdropExcludesWindow(mode: window.mode, isMinimized: window.isMinimized),
                          let frame = context.physicalFrame(id)
                    else {
                        continue
                    }
                    result.append((id, frame, stack[index].id))
                }
            }
        }
        return result
    }

    /// SM-11: a covered window that changed workspace may be tried again;
    /// a parked miss that shows again is released (captured like any
    /// visible window). SM-20: so is every window of a workspace that just
    /// became shown or adjacent to a shown one (a pruned image comes back
    /// before a switch can need it). Bookkeeping follows the covered set.
    private func updateCoverageState(_ coverage: [(id: WindowID, frame: CGRect, workspace: WorkspaceID)]) {
        let session = context.session()
        var near: Set<WorkspaceID> = []
        for display in session.manager.displayIDs {
            let stack = session.manager.stack(on: display)
            guard let active = stack.firstIndex(where: { $0.id == session.manager.activeID(on: display) }) else {
                continue
            }
            for index in active - 1...active + 1 where stack.indices.contains(index) {
                near.insert(stack[index].id)
            }
        }
        let entered = near.subtracting(nearWorkspaces)
        nearWorkspaces = near
        var seen: [WindowID: WorkspaceID] = [:]
        for item in coverage {
            if let previous = workspaceOf[item.id], previous != item.workspace {
                tried.remove(item.id)
            } else if entered.contains(item.workspace) {
                tried.remove(item.id)
            }
            seen[item.id] = item.workspace
        }
        workspaceOf = seen
        tried.formIntersection(seen.keys)
        let screens = context.displays().map(\.frame)
        for id in parkedMisses {
            if let frame = context.physicalFrame(id), !snapshotFrameIsOffScreen(frame, displays: screens) {
                parkedMisses.remove(id)
                tried.remove(id)
            }
        }
    }

    /// SM-11: some covered window has no image (SM-24: or only a stale one)
    /// and was not tried yet (SM-13: and the cap still has room for
    /// coverage). SM-21: or some strip window lacks a usable current-size
    /// image and was not asked for in this pass (the cap never stops the strip).
    private func coverageDue() -> Bool {
        let stripDue = !snapshotStripSelection(
            cache: cache, strip: coverageStrip().filter { !stripPass.contains($0.id) }, dirty: [:],
            excluded: parkedMisses, now: context.now()
        ).isEmpty
        let now = context.now()
        return stripDue || (!coverageStopped && coverageSet().contains {
            lacksFreshImage($0.id, now: now) && !tried.contains($0.id) && !parkedMisses.contains($0.id)
        })
    }

    /// SM-24: an image past the max age still flies, so nothing prunes it;
    /// coverage treats it like a missing one (once per window until its
    /// workspace comes near again, as a pruned image used to be).
    private func lacksFreshImage(_ id: WindowID, now: TimeInterval) -> Bool {
        guard let entry = cache.entry(id) else {
            return true
        }
        return now - entry.capturedAt > snapshotMaxAge
    }

    /// Every managed window that can fly, with its frame: left out of each
    /// backdrop so it shows only what the overlay does not draw (floating
    /// windows stay in it, `backdropExcludesWindow`).
    private func managedFrames() -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        for window in context.session().registry.managedWindows()
        where backdropExcludesWindow(mode: window.mode, isMinimized: window.isMinimized) {
            if let frame = context.physicalFrame(window.id) {
                frames[window.id] = frame
            }
        }
        return frames
    }

    /// SM-09: display frames whose backdrop must be captured in this run.
    /// A settle run captures a missing or expired backdrop and one whose
    /// unmanaged on-screen windows changed; a dirty-only run only an
    /// explicitly dirtied one. The renderer alone needs backdrops.
    private func backdropFrames(full: Bool, managed: [WindowID: CGRect], now: TimeInterval) -> [CGRect] {
        guard context.rendererAvailable() else {
            return []
        }
        let frames = context.displays().map(\.frame)
        if full {
            let print = unmanagedWindowFingerprint(server: context.serverWindows(), managed: managed, ownPid: context.ownPid)
            if let previous = unmanagedFingerprint, previous != print {
                backdropDirty = true
            }
            unmanagedFingerprint = print
        }
        return frames.filter { frame in
            guard let entry = cache.backdrop(for: frame) else {
                return full
            }
            return backdropDirty || (full && !snapshotBackdropUsable(entry, now: now))
        }
    }

    private func run(token: Int) {
        guard token == self.token, !context.isShuttingDown(), !context.isFlightActive(),
              !context.isMotionActive(), cacheWanted()
        else {
            return
        }
        guard !busy else {
            again = true
            againFull = againFull || pendingFull
            return
        }
        let full = pendingFull
        pendingFull = false
        let now = context.now()
        if full {
            prune(now: now)
        }
        let coverage = coverageSet()
        updateCoverageState(coverage)
        let refresh = refreshSet()
        let refreshIDs = Set(refresh.map(\.id))
        // A dirty mark only lives while the window can be captured, so the
        // set drains (SM-11: marks of minimized, floating or gone windows).
        let capturable = refreshIDs.union(coverage.map(\.id))
        dirty = dirty.filter { capturable.contains($0.key) }
        let wanted = (full ? refresh : refresh.filter { dirty[$0.id] != nil }).filter { !parkedMisses.contains($0.id) }
        // SM-22: the shown strips want full resolution, everything else half.
        let shown = Set(stripPlan().strip.map(\.id))
        // SM-21: the rest of the shown strips, every window without a
        // usable current-size image whether tried or not (parked misses
        // excluded), after the refresh set.
        let strip = coverageStrip().filter { !refreshIDs.contains($0.id) && (full || dirty[$0.id] != nil) }
        let stripIDs = Set(strip.map(\.id))
        // SM-11 coverage: the other workspaces' windows without a fresh
        // image (once each) and the dirty ones, after the strips.
        let extra = coverage.filter { item in
            !refreshIDs.contains(item.id) && !stripIDs.contains(item.id) && !parkedMisses.contains(item.id)
                && (dirty[item.id] != nil
                    || (full && !coverageStopped && lacksFreshImage(item.id, now: now) && !tried.contains(item.id)))
        }.map { (id: $0.id, frame: $0.frame) }
        // SM-21: a coverage stage does not ask again for a window this
        // pass already asked for (unless it is dirty again).
        let selected = Array((
            snapshotRefreshSelection(cache: cache, wanted: wanted, dirty: dirty, now: now, fullResolution: shown)
                + snapshotStripSelection(cache: cache, strip: strip, dirty: dirty, excluded: parkedMisses, now: now)
                + snapshotRefreshSelection(cache: cache, wanted: extra, dirty: dirty, now: now, fullResolution: shown)
        ).filter { !full || !stripPass.contains($0.id) || dirty[$0.id] != nil }.prefix(Self.maxWindows))
        let managed = managedFrames()
        let backdrops = backdropFrames(full: full, managed: managed, now: now)
        let (screens, primary) = context.captureScreens()
        let backdropIDs = screens.filter { screen in backdrops.contains(screen.frame) }.map(\.id)
        guard !selected.isEmpty || !backdropIDs.isEmpty else {
            if full {
                context.log(.debug, "snapshot refresh skipped wanted=\(wanted.count) fresh")
            }
            return
        }
        let reason = snapshotRefreshReason(causes: selected.map(\.cause), backdrop: !backdropIDs.isEmpty)
        let frames = Dictionary((wanted + strip + extra).map { ($0.id, $0.frame) }) { first, _ in first }
        let requested = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, frames[$0.id]!) })
        let half = Set(requested.keys.filter { snapshotCaptureResolution($0, shown: shown) == .half })
        tried.formUnion(requested.keys)
        stripPass.formUnion(requested.keys)
        let request = SnapshotCaptureRequest(
            windows: requested, halfResolution: half,
            displays: screens, primaryDisplayHeight: primary, includeBackdrop: false,
            backdropDisplayIDs: backdropIDs, backdropExclusions: managed,
            budgetMilliseconds: 1500, logLevel: .debug, reason: reason
        )
        busy = true
        context.capture(request) { [weak self] outcome in
            self?.scheduler.async { [weak self] in
                self?.finish(outcome, requested: requested, half: half, requestedBackdrops: backdrops)
            }
        }
    }

    /// SM-20: drops what no flight can use (`SnapshotCache.prune`), one
    /// debug line per reason. A window left without images left the cache:
    /// stopped coverage may resume (only for windows never tried).
    private func prune(now: TimeInterval) {
        let pruned = cache.prune(
            now: now, currentFrame: context.physicalFrame, displayFrames: context.displays().map(\.frame)
        )
        for line in pruned.logLines {
            context.log(.debug, line)
        }
        if !pruned.emptied.isEmpty {
            coverageStopped = false
        }
    }

    /// SM-20: the system reports memory pressure (a `DispatchSource`
    /// memory-pressure event, delivered on the session queue; no timer).
    /// SM-21: a warning is not a purge: the shown and adjacent workspaces
    /// keep every image, the others lose stale or other-size images;
    /// critical keeps only the shown strips' current-size images.
    /// Both keep the backdrops of the shown displays. Dropped hidden
    /// windows stay tried: coverage does not bring them back before their
    /// workspace becomes adjacent. Normal after a warning or critical
    /// starts one settle-like run that re-captures what the strips lack;
    /// normal otherwise changes nothing.
    public func noteMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let level: SnapshotMemoryPressure
        if event.contains(.critical) {
            level = .critical
        } else if event.contains(.warning) {
            level = .warning
        } else {
            guard underPressure else {
                return
            }
            underPressure = false
            context.log(.info, "snapshot cache pressure level=normal")
            schedule()
            return
        }
        underPressure = true
        let plan = stripPlan()
        let freed = cache.relieve(
            level, shown: Set(plan.strip.map(\.id)), adjacent: plan.adjacent, currentFrame: context.physicalFrame,
            displayFrames: context.displays().map(\.frame), now: context.now()
        )
        context.log(.info, snapshotPressureLogLine(level: level, freed: freed))
    }

    private func finish(
        _ outcome: SnapshotCaptureOutcome, requested: [WindowID: CGRect], half: Set<WindowID>,
        requestedBackdrops: [CGRect]
    ) {
        busy = false
        guard !context.isShuttingDown(), cacheWanted() else {
            return
        }
        let now = context.now()
        for (id, snapshot) in outcome.images {
            cache.store(
                id, image: snapshot.image, frame: snapshot.frame,
                pixels: snapshot.image.width * snapshot.image.height, at: now,
                resolution: half.contains(id) ? .half : .full, fill: snapshot.fill
            )
            dirty.removeValue(forKey: id)
            undrawnWindows.remove(id)
        }
        noteMisses(outcome.misses, requested: requested, now: now)
        for backdrop in outcome.backdrops {
            cache.storeBackdrop(
                image: backdrop.image, displayFrame: backdrop.displayFrame,
                pixels: backdrop.image.width * backdrop.image.height, at: now
            )
        }
        if !requestedBackdrops.isEmpty, requestedBackdrops.allSatisfy({ frame in
            outcome.backdrops.contains { $0.displayFrame == frame }
        }) {
            backdropDirty = false
        }
        // Gone or minimized windows lose their image; the rest stays under the cap.
        let live = Set(context.session().registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        if !cache.retain(only: live).isEmpty {
            coverageStopped = false
        }
        undrawnWindows.formIntersection(live)
        let displayPixels = context.captureScreens().screens.map {
            Int($0.frame.width * $0.scale) * Int($0.frame.height * $0.scale)
        }.max() ?? 0
        // SM-13: the windows on screen and next to them are evicted last;
        // a size a window is not at now goes before its current one.
        // SM-21: the shown strips' current-size images are never evicted.
        let pinned = Set(stripPlan().strip.map(\.id))
        let protected = Set(refreshSet().map(\.id))
        let capPixels = snapshotCacheCapPixels(displayPixels: displayPixels, physicalMemory: context.physicalMemory)
        if loggedCapPixels != capPixels {
            loggedCapPixels = capPixels
            context.log(.debug, snapshotCacheCapLogLine(capPixels: capPixels, physicalMemory: context.physicalMemory))
        }
        let evicted = cache.enforce(
            capPixels: capPixels, protected: protected, pinned: pinned, currentFrame: context.physicalFrame
        )
        if cache.totalPixels + cache.backdropPixels > capPixels {
            if !stripCapLogged {
                stripCapLogged = true
                let images = pinned.reduce(0) { $0 + cache.entries(of: $1).count }
                context.log(.debug, snapshotStripCapLogLine(images: images))
            }
        } else {
            stripCapLogged = false
        }
        // SM-22: a hidden window whose full image went is captured again at
        // half by coverage; only a half image going stops coverage.
        for eviction in evicted where eviction.resolution == .full && cache.entry(eviction.id) == nil {
            tried.remove(eviction.id)
        }
        if evicted.contains(where: { $0.resolution == .half }), context.rendererAvailable(), !coverageStopped {
            // The cap cannot hold more: further stages would evict each other.
            coverageStopped = true
            context.log(
                .info,
                "snapshot coverage stopped cap reached images=\(cache.imageCount) pixels=\(cache.totalPixels)"
            )
        }
        context.log(
            .debug,
            "snapshot cache entries=\(cache.count) images=\(cache.imageCount) pixels=\(cache.totalPixels) "
                + "backdropPixels=\(cache.backdropPixels) evicted=\(evicted.count) dirty=\(dirty.count)"
        )
        if again {
            again = false
            let full = againFull || coverageDue()
            againFull = false
            scheduleRun(delay: 0.05, full: full)
        } else if coverageDue() {
            // SM-11: the next coverage stage.
            scheduleRun(delay: Self.stageDelay, full: true)
        }
    }

    /// SM-11: every miss is attributed at debug (once per window and reason
    /// per minute). A window that missed while parked or off screen for any
    /// reason but the budget (unmatched where macOS clamped it, failed or
    /// blank because it is not drawn) is not retried, and its dirty mark is
    /// dropped, until it shows again; its previous image stays. SM-31: a
    /// shown-strip window still at the requested frame that macOS does not
    /// draw (`snapshotUndrawnWindows`) loses its image instead.
    private func noteMisses(_ misses: [WindowID: SnapshotMiss], requested: [WindowID: CGRect], now: TimeInterval) {
        guard !misses.isEmpty else {
            return
        }
        let screens = context.displays().map(\.frame)
        for (id, miss) in misses.sorted(by: { $0.key < $1.key }) {
            if missThrottle.shouldLog(id, reason: miss, now: now) {
                context.log(.debug, snapshotMissLogLine(id: id, reason: miss, app: context.appName(id.pid)))
            }
            if miss != .overBudget, let frame = requested[id], snapshotFrameIsOffScreen(frame, displays: screens) {
                parkedMisses.insert(id)
                dirty.removeValue(forKey: id)
            }
        }
        var shown: [WindowID: CGRect] = [:]
        for item in stripPlan().strip where misses[item.id] != nil && requested[item.id] == item.frame {
            shown[item.id] = item.frame
        }
        let undrawn = snapshotUndrawnWindows(
            misses: misses, frames: shown, server: context.serverWindows(), viewports: screens
        )
        for id in undrawn.sorted() {
            markUndrawn(id, reason: .undrawn)
        }
    }
}
