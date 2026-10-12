import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
@preconcurrency import ScreenCaptureKit

// SM-02: ScreenCaptureKit capture of managed windows and display backdrops.
// Compile-checked only (needs the Screen Recording permission and a screen);
// every decision it makes lives in GioCore `SnapshotPlanning` and is tested.
//
// Coordinates: `SCWindow.frame` / `SCDisplay.frame` are global points with a
// top-left origin (primary display), the same as CoreGraphics window bounds.
// Windows are matched against `CGWindowListCopyWindowInfo` bounds (already
// converted to Cocoa) and joined to ScreenCaptureKit by `CGWindowID`, so the
// cached `SCWindow` frames (which go stale as Gio moves windows) are never
// compared. SM-17: same-size windows the frames cannot tell apart are told
// apart by title (listed window name vs AX title), compared in memory only.
// SM-20: equal or missing titles fall back to the stacking order (the app's
// AX window order vs the on-screen window list), never learned.
//
// Deployment target is macOS 13 but `SCScreenshotManager` needs macOS 14:
// on 13 every window is reported as a failed miss and callers fall back to
// the Accessibility motion.

/// One captured window image. `frame` is the Cocoa frame the window had when
/// requested and `scale` the scale the image was rendered at (SM-22: half the
/// backing scale for a half-resolution window).
public struct CapturedSnapshot: @unchecked Sendable {
    public let id: WindowID
    public let image: CGImage
    public let frame: CGRect
    public let scale: CGFloat
    /// SM-27/SM-30: the flat fill a resize shows where the frame outgrows the
    /// image (`snapshotContentFill` of its right half); nil when see-through.
    public let fill: ThemeColor?
}

/// A display image without the animated windows and Gio's own windows.
public struct CapturedBackdrop: @unchecked Sendable {
    public let displayID: UInt32
    public let image: CGImage
    public let frame: CGRect
    public let scale: CGFloat
}

public struct SnapshotCaptureRequest: Sendable {
    /// Managed windows to capture and their current Cocoa frames.
    public var windows: [WindowID: CGRect]
    /// SM-22: windows captured at half the backing scale (hidden
    /// workspaces); the others at the backing scale.
    public var halfResolution: Set<WindowID>
    public var displays: [SnapshotDisplay]
    /// Height of the primary display, for the top-left to Cocoa flip.
    public var primaryDisplayHeight: CGFloat
    /// Backdrops for every display the captured windows touch (Diagnostics).
    public var includeBackdrop: Bool
    /// SM-09: backdrops for exactly these displays (the cache refresh).
    public var backdropDisplayIDs: [UInt32]
    /// SM-09: every managed window (with its frame), left out of each
    /// backdrop besides the captured ones and Gio's own windows, so the
    /// backdrop shows only the desktop and what Gio does not manage.
    public var backdropExclusions: [WindowID: CGRect]
    public var budgetMilliseconds: Int
    /// Debug measurement: a generous cap instead of the budget, and the
    /// result carries a latency breakdown (Diagnostics "Test snapshot capture").
    public var measure: Bool
    /// Level of the `snapshot capture` summary: background cache refreshes log at debug.
    public var logLevel: LogLevel
    /// Why the capture runs, carried into the summary line.
    public var reason: SnapshotCaptureReason

    /// Cap used in measure mode so slow captures still report their latency.
    public static let measureCapMilliseconds = 2000

    public init(
        windows: [WindowID: CGRect], halfResolution: Set<WindowID> = [], displays: [SnapshotDisplay],
        primaryDisplayHeight: CGFloat,
        includeBackdrop: Bool = true, backdropDisplayIDs: [UInt32] = [], backdropExclusions: [WindowID: CGRect] = [:],
        budgetMilliseconds: Int = SnapshotBudget.defaultMilliseconds,
        measure: Bool = false, logLevel: LogLevel = .info, reason: SnapshotCaptureReason = .settle
    ) {
        self.logLevel = logLevel
        self.windows = windows
        self.halfResolution = halfResolution
        self.displays = displays
        self.primaryDisplayHeight = primaryDisplayHeight
        self.includeBackdrop = includeBackdrop
        self.backdropDisplayIDs = backdropDisplayIDs
        self.backdropExclusions = backdropExclusions
        self.budgetMilliseconds = budgetMilliseconds
        self.measure = measure
        self.reason = reason
    }
}

/// Images are owned by the caller: nothing is cached here, so releasing the
/// result releases the memory.
public struct SnapshotCaptureResult: @unchecked Sendable {
    public let snapshots: [WindowID: CapturedSnapshot]
    public let backdrops: [UInt32: CapturedBackdrop]
    public let summary: SnapshotCaptureSummary
    /// Only in measure mode.
    public let measurement: SnapshotMeasurement?
}

public final class SnapshotCapturer: @unchecked Sendable {
    public static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    private let ownPid: pid_t
    private let lock = NSLock()
    // Guarded by `lock`. Type-erased so the class is usable on macOS 13.
    private var content: AnyObject?
    /// Guarded by `lock`. SM-09: windows whose blank capture was logged, so
    /// a window that stays blank logs once.
    private var blankLogged: Set<WindowID> = []
    /// Guarded by `lock`. SM-13: CGWindowIDs learned while windows were on
    /// screen, so same-size windows parked at one frame are told apart.
    private var windowIDs = SnapshotWindowIDBook()
    /// Guarded by `lock`. SM-17: reads a managed window's current AX title
    /// for the title tie-break; set once by the session host.
    private var titleReader: (@Sendable (WindowID) -> String?)?
    /// Guarded by `lock`. SM-20: reads an app's managed windows in its AX
    /// window order for the stacking-order tie-break; set once by the host.
    private var orderReader: (@Sendable (pid_t) -> [WindowID])?

    public init(ownPid: pid_t = getpid()) {
        self.ownPid = ownPid
    }

    /// SM-17: `reader` returns the window's AX title (`kAXTitleAttribute`)
    /// and is called on the capture task, never on the session queue, and
    /// only for windows the frames left ambiguous. Titles are compared and
    /// dropped; nothing here logs or keeps them.
    public func setWindowTitleReader(_ reader: @escaping @Sendable (WindowID) -> String?) {
        lock.withLock { titleReader = reader }
    }

    /// SM-20: `reader` returns the app's managed windows in its
    /// `kAXWindowsAttribute` order (`axWindowOrder`), called on the capture
    /// task, never on the session queue, and only for apps with windows the
    /// frames and titles left ambiguous. No titles involved.
    public func setWindowOrderReader(_ reader: @escaping @Sendable (pid_t) -> [WindowID]) {
        lock.withLock { orderReader = reader }
    }

    /// True the first time `id` captures blank.
    private func noteBlank(_ id: WindowID) -> Bool {
        lock.withLock { blankLogged.insert(id).inserted }
    }

    /// Never throws and never blocks past the budget (plus scheduling): work
    /// that has not finished by then is reported as a miss and dropped.
    public func capture(_ request: SnapshotCaptureRequest) async -> SnapshotCaptureResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let result: SnapshotCaptureResult
        if #available(macOS 14.0, *) {
            result = await captureSCK(request, start: start)
        } else {
            let ids = request.windows.keys.sorted()
            result = SnapshotCaptureResult(
                snapshots: [:], backdrops: [:],
                summary: makeSnapshotSummary(
                    requested: ids, matches: Dictionary(uniqueKeysWithValues: ids.map { ($0, .matched(0)) }),
                    captured: [], failed: Set(ids), backdropsRequested: 0, backdropsCaptured: 0,
                    elapsedMilliseconds: 0, reason: request.reason
                ),
                measurement: nil
            )
        }
        GioLog.record(request.logLevel, result.summary.logLine)
        if let measurement = result.measurement {
            GioLog.record(.info, measurement.logLine)
        }
        return result
    }

    /// Refreshes the shareable content in the background so requests on the
    /// motion hot path hit the cache. Call when the managed window set
    /// changes and at session start (after Screen Recording is granted).
    /// Never throws; the fetch time is logged at debug.
    public func prefetch(managed: Set<WindowID>) async {
        guard #available(macOS 14.0, *) else {
            return
        }
        _ = await refreshCache(managed: managed)
    }

    /// SM-14: whether each window painted at its probe's frame (its target,
    /// already written): a capture `snapshotPaintCheckPixelSize` wide and the
    /// SM-10 blank test (sparse grid confirmed by the dense scan). SM-29: a
    /// resized window is also judged on the size the WindowServer reports
    /// and on the strips it grew into (`snapshotPaintVerdict`); every
    /// capture's sparse samples go back for the stability check. A window
    /// that cannot be matched or captured is left out (`unknown` for the
    /// caller). Nothing is cached; one debug line per check.
    public func paintCheck(
        windows: [WindowID: SnapshotPaintProbe], displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat
    ) async -> SnapshotPaintAnswer {
        guard #available(macOS 14.0, *) else {
            return SnapshotPaintAnswer()
        }
        return await paintCheckSCK(windows: windows, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// SM-30: one capture of `id` at its probe's target frame, full
    /// resolution, for its layer to fade to mid-flight: the SM-29 verdict
    /// (size, blank, grown strips), its fill and sparse samples, and what
    /// the stale test compares (the part both sizes share, in the start
    /// image and in the capture, when it shrank; the cached target image).
    /// Nil when the window cannot be matched or captured. Nothing is cached
    /// here; one debug line per capture.
    public func freshCapture(
        _ id: WindowID, probe: SnapshotFreshProbe<CGImage>, displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat
    ) async -> SnapshotFreshRead<CGImage>? {
        guard #available(macOS 14.0, *) else {
            return nil
        }
        return await freshCaptureSCK(id, probe: probe, displays: displays, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// SM-13/SM-17/SM-20: matches `managed` (learned ids first, then
    /// frames), breaks the ties of same-size windows by title, then by
    /// stacking order, and teaches the book: the on-screen matches when
    /// `displays` are given (a capture run), and always the title-broken
    /// ones (`snapshot match tie-break`, debug). Order-broken matches are
    /// never learned: a wrong rank would outlive the window showing (the
    /// learned id beats the frame), so they are derived again each run and
    /// a visible window is matched (and learned) by its frame.
    private func match(
        _ managed: [WindowID: CGRect], candidates: [SnapshotCandidate], learningOn displays: [CGRect]?
    ) -> [WindowID: SnapshotMatch] {
        var matches = lock.withLock {
            matchSnapshotCandidates(managed: managed, candidates: candidates, known: windowIDs.known)
        }
        let ties = titleTieBreaks(managed, candidates: candidates, matches: matches)
        for (id, windowID) in ties.sorted(by: { $0.key < $1.key }) {
            matches[id] = .matched(windowID)
            GioLog.record(.debug, snapshotTieBreakLogLine(id, by: .title))
        }
        let ordered = orderTieBreaks(managed, candidates: candidates, matches: matches)
        let learnable = matches
        for (id, windowID) in ordered.sorted(by: { $0.key < $1.key }) {
            matches[id] = .matched(windowID)
            GioLog.record(.debug, snapshotTieBreakLogLine(id, by: .order))
        }
        lock.withLock {
            if let displays {
                windowIDs.learn(
                    matches: learnable, frames: managed, displays: displays, candidates: candidates,
                    identified: Set(ties.keys)
                )
            } else if !ties.isEmpty {
                windowIDs.learn(
                    matches: ties.mapValues { .matched($0) }, frames: managed.filter { ties[$0.key] != nil },
                    displays: [], candidates: candidates, identified: Set(ties.keys)
                )
            }
        }
        return matches
    }

    /// SM-17: the AX titles of the ambiguous windows whose app lists window
    /// names, read here (off the session queue, outside the lock), compared
    /// by `snapshotTitleTieBreaks` and dropped on return.
    private func titleTieBreaks(
        _ managed: [WindowID: CGRect], candidates: [SnapshotCandidate], matches: [WindowID: SnapshotMatch]
    ) -> [WindowID: UInt32] {
        let named = Set(candidates.filter { $0.title != nil }.map(\.pid))
        let ambiguous = matches.keys.filter { matches[$0] == .ambiguous && named.contains($0.pid) }
        guard !ambiguous.isEmpty, let read = lock.withLock({ titleReader }) else {
            return [:]
        }
        var titles: [WindowID: String] = [:]
        for id in ambiguous {
            titles[id] = read(id)
        }
        return snapshotTitleTieBreaks(managed: managed, candidates: candidates, matches: matches, titles: titles)
    }

    /// SM-20: the AX window order of the apps with windows still ambiguous
    /// and the on-screen stacking of their windows, read here (off the
    /// session queue, outside the lock) for `snapshotOrderTieBreaks`.
    private func orderTieBreaks(
        _ managed: [WindowID: CGRect], candidates: [SnapshotCandidate], matches: [WindowID: SnapshotMatch]
    ) -> [WindowID: UInt32] {
        let pids = Set(matches.filter { $0.value == .ambiguous }.keys.map(\.pid))
        guard !pids.isEmpty, let read = lock.withLock({ orderReader }) else {
            return [:]
        }
        var axOrder: [pid_t: [WindowID]] = [:]
        for pid in pids.sorted() {
            axOrder[pid] = read(pid)
        }
        return snapshotOrderTieBreaks(
            managed: managed, candidates: candidates, matches: matches, axOrder: axOrder,
            stacking: windowServerStacking(pids: pids)
        )
    }

    // MARK: - ScreenCaptureKit (macOS 14+)

    @available(macOS 14.0, *)
    private func paintCheckSCK(
        windows probes: [WindowID: SnapshotPaintProbe], primaryDisplayHeight: CGFloat
    ) async -> SnapshotPaintAnswer {
        let began = DispatchTime.now().uptimeNanoseconds
        let windows = probes.mapValues(\.frame)
        let candidates = windowServerSnapshotCandidates(
            pids: Set(windows.keys.map(\.pid)), displayHeight: primaryDisplayHeight
        )
        let matches = match(windows, candidates: candidates, learningOn: nil)
        let matched = windows.keys.sorted().compactMap { id -> (id: WindowID, windowID: UInt32)? in
            guard case .matched(let windowID)? = matches[id] else {
                return nil
            }
            return (id, windowID)
        }
        let lookup = await ensureCache(
            managed: Set(windows.keys), needed: Set(matched.map(\.windowID)), needsDisplays: false
        )
        var answer = SnapshotPaintAnswer()
        if let cache = lookup.cache {
            await withTaskGroup(of: (WindowID, SnapshotPaintVerdict, [UInt32]).self) { group in
                for entry in matched {
                    guard let window = cache.windows[entry.windowID], let probe = probes[entry.id] else {
                        continue
                    }
                    let boxed = Box(value: window)
                    let pixels = snapshotPaintCheckPixelSize(points: probe.frame.size)
                    let windowSize = candidates.first { $0.windowID == entry.windowID }?.frame.size
                    group.addTask {
                        guard let image = try? await Self.captureWindow(boxed.value, pixels: pixels) else {
                            return (entry.id, .unknown, [])
                        }
                        let samples = snapshotSamples(of: image)
                        let strips = probe.resizedFrom.map {
                            snapshotGrownStrips(
                                from: $0, to: probe.frame.size, pixelWidth: image.width, pixelHeight: image.height
                            )
                        } ?? []
                        let verdict = snapshotPaintVerdict(
                            probe, windowSize: windowSize, samples: samples,
                            dense: { snapshotDenseSamples(of: image) },
                            strips: strips.map { snapshotStripSamples(of: image, in: $0) }
                        )
                        return (entry.id, verdict, samples)
                    }
                }
                for await (id, verdict, samples) in group {
                    answer.verdicts[id] = verdict
                    answer.samples[id] = samples
                }
            }
        }
        let millis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        let verdicts = answer.verdicts.values
        GioLog.record(
            .debug,
            "snapshot paint check windows=\(windows.count) painted=\(verdicts.filter { $0 == .painted }.count) "
                + "blank=\(verdicts.filter { $0 == .blank }.count) partial=\(verdicts.filter { $0 == .partial }.count) "
                + "ms=\(Int(millis.rounded()))"
        )
        return answer
    }

    @available(macOS 14.0, *)
    private func freshCaptureSCK(
        _ id: WindowID, probe: SnapshotFreshProbe<CGImage>, displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat
    ) async -> SnapshotFreshRead<CGImage>? {
        let began = DispatchTime.now().uptimeNanoseconds
        let frame = probe.paint.frame
        let candidates = windowServerSnapshotCandidates(pids: [id.pid], displayHeight: primaryDisplayHeight)
        guard case .matched(let windowID)? = match([id: frame], candidates: candidates, learningOn: nil)[id],
              let window = await ensureCache(managed: [id], needed: [windowID], needsDisplays: false).cache?
                  .windows[windowID]
        else {
            GioLog.record(.debug, "snapshot fresh capture id=\(id.pid):\(id.elementID) ms=0 ok=false")
            return nil
        }
        let image = try? await Self.captureWindow(
            window, size: frame.size, scale: backingScale(for: frame, displays: displays)
        )
        let millis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        GioLog.record(
            .debug, "snapshot fresh capture id=\(id.pid):\(id.elementID) ms=\(Int(millis.rounded())) ok=\(image != nil)"
        )
        guard let image else {
            return nil
        }
        let windowSize = candidates.first { $0.windowID == windowID }?.frame.size
        let samples = snapshotSamples(of: image)
        let strips = probe.paint.resizedFrom.map {
            snapshotGrownStrips(from: $0, to: frame.size, pixelWidth: image.width, pixelHeight: image.height)
        } ?? []
        let paint = snapshotPaintVerdict(
            probe.paint, windowSize: windowSize, samples: samples, dense: { snapshotDenseSamples(of: image) },
            strips: strips.map { snapshotStripSamples(of: image, in: $0) }
        )
        var startRegion: [UInt32]?
        var freshRegion: [UInt32]?
        if let start = probe.start, let region = snapshotFreshRegion(start: start.size, target: frame.size) {
            startRegion = snapshotRegionSamples(
                of: start.image,
                in: snapshotRegionPixels(
                    region, of: start.size, pixelWidth: start.image.width, pixelHeight: start.image.height
                )
            )
            freshRegion = snapshotRegionSamples(
                of: image, in: snapshotRegionPixels(region, of: frame.size, pixelWidth: image.width, pixelHeight: image.height)
            )
        }
        return SnapshotFreshRead(
            image: image, fill: snapshotContentFill(samples: snapshotContentSamples(of: image)), windowSize: windowSize,
            paint: paint, samples: samples, startRegion: startRegion, freshRegion: freshRegion,
            cached: probe.cached.map { snapshotSamples(of: $0.image) }
        )
    }

    @available(macOS 14.0, *)
    private final class Cache {
        let windows: [UInt32: SCWindow]
        let displays: [UInt32: SCDisplay]
        let managed: Set<WindowID>

        init(content: SCShareableContent, managed: Set<WindowID>) {
            windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            displays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
            self.managed = managed
        }
    }

    /// ScreenCaptureKit objects are immutable handles that Apple documents as
    /// usable from any queue; the box carries them into concurrent tasks.
    private struct Box<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Per-capture timings, written from concurrent tasks.
    private final class Timings: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [Double] = []
        private var backdrop: Double?
        private(set) var fetch: Double = 0
        private(set) var fetchCached = true

        func setFetch(_ milliseconds: Double, cached: Bool) {
            lock.withLock {
                fetch = milliseconds
                fetchCached = cached
            }
        }

        func addWindow(_ milliseconds: Double) {
            lock.withLock { windows.append(milliseconds) }
        }

        func addBackdrop(_ milliseconds: Double) {
            lock.withLock { backdrop = Swift.max(backdrop ?? 0, milliseconds) }
        }

        func read() -> (fetch: Double, cached: Bool, windows: [Double], backdrop: Double?) {
            lock.withLock { (fetch, fetchCached, windows, backdrop) }
        }
    }

    /// Collects results from concurrent captures and resumes the waiter once:
    /// when everything finished or when the budget expired, whichever comes
    /// first. Late results after that are dropped.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        private var pending = 0
        private(set) var images: [WindowID: CGImage] = [:]
        private(set) var failed: Set<WindowID> = []
        /// SM-09: captured but blank; reported as a miss so the cache keeps its previous image.
        private(set) var blank: Set<WindowID> = []
        private(set) var backdropImages: [UInt32: CGImage] = [:]
        private(set) var backdropsFailed = 0

        func wait(install: () -> Void) async {
            await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
                lock.lock()
                continuation = next
                lock.unlock()
                install()
            }
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        /// Sets how many jobs will report. Zero finishes immediately.
        func expect(_ count: Int) {
            lock.lock()
            pending = count
            let done = count == 0
            lock.unlock()
            if done {
                finish()
            }
        }

        /// The shareable content is unavailable: every matched window failed.
        func failAll(_ ids: [WindowID]) {
            lock.lock()
            if !finished {
                failed.formUnion(ids)
            }
            lock.unlock()
            finish()
        }

        func complete(window id: WindowID, image: CGImage?, isBlank: Bool = false) {
            lock.lock()
            if !finished {
                if let image, !isBlank {
                    images[id] = image
                } else if isBlank {
                    blank.insert(id)
                } else {
                    failed.insert(id)
                }
            }
            let done = advance()
            lock.unlock()
            if done {
                finish()
            }
        }

        func complete(display id: UInt32, image: CGImage?) {
            lock.lock()
            if !finished {
                if let image {
                    backdropImages[id] = image
                } else {
                    backdropsFailed += 1
                }
            }
            let done = advance()
            lock.unlock()
            if done {
                finish()
            }
        }

        /// Call with the lock held.
        private func advance() -> Bool {
            pending -= 1
            return pending == 0
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let next = continuation
            continuation = nil
            lock.unlock()
            next?.resume()
        }

        func snapshot() -> (
            images: [WindowID: CGImage], failed: Set<WindowID>, blank: Set<WindowID>, backdrops: [UInt32: CGImage]
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (images, failed, blank, backdropImages)
        }
    }

    @available(macOS 14.0, *)
    private func captureSCK(_ request: SnapshotCaptureRequest, start: UInt64) async -> SnapshotCaptureResult {
        let ids = request.windows.keys.sorted()
        // SM-09: the exclusions (every managed window) are matched next to
        // the captured ones so each backdrop leaves all of them out.
        let exclusions = request.backdropExclusions.filter { request.windows[$0.key] == nil }
        let pids = Set(ids.map(\.pid)).union(exclusions.keys.map(\.pid))
        let candidates = windowServerSnapshotCandidates(pids: pids, displayHeight: request.primaryDisplayHeight)
        let managed = request.windows.merging(exclusions) { captured, _ in captured }
        let allMatches = match(managed, candidates: candidates, learningOn: request.displays.map(\.frame))
        let matches = allMatches.filter { request.windows[$0.key] != nil }
        let excludedMatches = allMatches.compactMap { entry -> UInt32? in
            guard exclusions[entry.key] != nil, case .matched(let windowID) = entry.value else {
                return nil
            }
            return windowID
        }
        let backdropDisplays = (
            Set(request.backdropDisplayIDs).union(
                request.includeBackdrop
                    ? displaysNeedingBackdrop(windowFrames: Array(request.windows.values), displays: request.displays)
                    : []
            )
        ).sorted()
        let excludedWindowIDs = Set(excludedMatches)
        let collector = Collector()
        let timings = Timings()
        let budget = request.measure ? SnapshotCaptureRequest.measureCapMilliseconds : request.budgetMilliseconds
        await collector.wait {
            let timer = DispatchWorkItem { collector.finish() }
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .milliseconds(budget), execute: timer
            )
            Task {
                await self.runJobs(
                    request: request, ids: ids, matches: matches, excludedWindowIDs: excludedWindowIDs,
                    backdropDisplays: backdropDisplays, collector: collector, timings: timings
                )
            }
        }
        let out = collector.snapshot()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        var snapshots: [WindowID: CapturedSnapshot] = [:]
        for (id, image) in out.images {
            let frame = request.windows[id] ?? .zero
            let scale = captureScale(request, id: id, frame: frame)
            snapshots[id] = CapturedSnapshot(
                id: id, image: image, frame: frame, scale: scale,
                fill: snapshotContentFill(samples: snapshotContentSamples(of: image))
            )
        }
        var backdrops: [UInt32: CapturedBackdrop] = [:]
        for (displayID, image) in out.backdrops {
            guard let display = request.displays.first(where: { $0.id == displayID }) else {
                continue
            }
            backdrops[displayID] = CapturedBackdrop(
                displayID: displayID, image: image, frame: display.frame, scale: display.scale
            )
        }
        let pixels = out.images.values.reduce(0) { $0 + $1.width * $1.height }
            + out.backdrops.values.reduce(0) { $0 + $1.width * $1.height }
        let summary = makeSnapshotSummary(
            requested: ids, matches: matches, captured: Set(snapshots.keys), failed: out.failed, blank: out.blank,
            backdropsRequested: backdropDisplays.count, backdropsCaptured: backdrops.count,
            elapsedMilliseconds: elapsed, pixels: pixels, reason: request.reason, half: request.halfResolution
        )
        var measurement: SnapshotMeasurement?
        if request.measure {
            let timed = timings.read()
            let sckIDs = lock.withLock { (content as? Cache).map { Set($0.windows.keys) } } ?? []
            var reasons: [SnapshotUnmatchedReason: Int] = [:]
            for id in ids {
                if let reason = classifySnapshotMiss(
                    pid: id.pid, match: matches[id] ?? .missing, candidates: candidates, sckWindowIDs: sckIDs
                ) {
                    reasons[reason, default: 0] += 1
                    if summary.misses[id] != nil {
                        GioLog.record(.info, "snapshot unmatched id=\(id.pid):\(id.elementID) reason=\(reason.rawValue)")
                    }
                }
            }
            measurement = SnapshotMeasurement(
                fetchMilliseconds: timed.fetch, fetchCached: timed.cached, windows: ids.count,
                windowMilliseconds: timed.windows, backdropMilliseconds: timed.backdrop,
                totalMilliseconds: elapsed, unmatchedReasons: reasons
            )
        }
        return SnapshotCaptureResult(
            snapshots: snapshots, backdrops: backdrops, summary: summary, measurement: measurement
        )
    }

    @available(macOS 14.0, *)
    private func runJobs(
        request: SnapshotCaptureRequest, ids: [WindowID], matches: [WindowID: SnapshotMatch],
        excludedWindowIDs: Set<UInt32>, backdropDisplays: [UInt32], collector: Collector,
        timings: Timings
    ) async {
        let managed = Set(ids).union(request.backdropExclusions.keys)
        let captured = Set(ids.compactMap { id -> UInt32? in
            if case .matched(let windowID)? = matches[id] { return windowID }
            return nil
        })
        // A backdrop must leave every managed window out, so their content
        // entries are needed too, and Gio's own on-screen panels (ring, dim,
        // overlay, main window; created lazily, so they may postdate the
        // last fetch): one WindowServer read, a refetch only when one is
        // missing. A captured window is only ever needed itself.
        let needed = backdropDisplays.isEmpty
            ? captured
            : captured.union(excludedWindowIDs).union(windowServerOnScreenWindowIDs(pid: ownPid))
        let fetchBegan = DispatchTime.now().uptimeNanoseconds
        let lookup = await ensureCache(managed: managed, needed: needed, needsDisplays: !backdropDisplays.isEmpty)
        timings.setFetch(Double(DispatchTime.now().uptimeNanoseconds - fetchBegan) / 1_000_000, cached: lookup.cached)
        guard let cache = lookup.cache, !collector.isFinished
        else {
            collector.failAll(ids.filter { if case .matched? = matches[$0] { return true } else { return false } })
            return
        }
        // Gio's own windows are excluded from every backdrop, next to the
        // captured ones and every other managed window (SM-09).
        let own = cache.windows.values.map {
            SnapshotCandidate(windowID: $0.windowID, pid: $0.owningApplication?.processID ?? 0, frame: .zero)
        }
        let excludedIDs = snapshotExclusions(
            candidates: own, animated: captured.union(excludedWindowIDs), ownPid: ownPid
        )
        let excluded = excludedIDs.compactMap { cache.windows[$0] }

        struct WindowJob {
            let id: WindowID
            let window: SCWindow?
        }
        var jobs: [WindowJob] = []
        for id in ids {
            guard case .matched(let windowID)? = matches[id] else {
                continue
            }
            jobs.append(WindowJob(id: id, window: cache.windows[windowID]))
        }
        collector.expect(jobs.count + backdropDisplays.count)
        for job in jobs {
            guard let window = job.window else {
                collector.complete(window: job.id, image: nil)
                continue
            }
            let frame = request.windows[job.id] ?? .zero
            let scale = captureScale(request, id: job.id, frame: frame)
            let boxed = Box(value: window)
            Task {
                let began = DispatchTime.now().uptimeNanoseconds
                let image = try? await Self.captureWindow(boxed.value, size: frame.size, scale: scale)
                let millis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                // SM-09: a blank capture (unpainted or stale window) is a miss;
                // the cache keeps the previous image. SM-10: the sparse grid's
                // verdict is confirmed by a coarse 64x64 scan.
                let blank = image.map { captured in
                    snapshotLooksBlank(samples: snapshotSamples(of: captured), dense: { snapshotDenseSamples(of: captured) })
                } ?? false
                GioLog.record(.debug, "snapshot window id=\(job.id.pid):\(job.id.elementID) ms=\(Int(millis.rounded())) ok=\(image != nil)")
                if blank, self.noteBlank(job.id) {
                    GioLog.record(.debug, "snapshot window blank id=\(job.id.pid):\(job.id.elementID)")
                }
                if image != nil, !blank {
                    timings.addWindow(millis)
                }
                collector.complete(window: job.id, image: image, isBlank: blank)
            }
        }
        for displayID in backdropDisplays {
            guard let display = cache.displays[displayID],
                  let info = request.displays.first(where: { $0.id == displayID })
            else {
                collector.complete(display: displayID, image: nil)
                continue
            }
            let boxedDisplay = Box(value: display)
            let boxedExcluded = Box(value: excluded)
            Task {
                let began = DispatchTime.now().uptimeNanoseconds
                let image = try? await Self.captureBackdrop(
                    boxedDisplay.value, excluding: boxedExcluded.value, size: info.frame.size, scale: info.scale
                )
                if image != nil {
                    timings.addBackdrop(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
                }
                collector.complete(display: displayID, image: image)
            }
        }
    }

    /// SM-22: the backing scale of the window's display, halved for a
    /// window the request wants at half resolution.
    private func captureScale(_ request: SnapshotCaptureRequest, id: WindowID, frame: CGRect) -> CGFloat {
        let resolution: SnapshotResolution = request.halfResolution.contains(id) ? .half : .full
        return backingScale(for: frame, displays: request.displays) * resolution.scale
    }

    /// The cached shareable content. The hot path only refreshes when a
    /// wanted window (or display) is missing from it; the background prefetch
    /// normally keeps it warm so the fetch stays outside the request budget.
    @available(macOS 14.0, *)
    private func ensureCache(
        managed: Set<WindowID>, needed: Set<UInt32>, needsDisplays: Bool
    ) async -> (cache: Cache?, cached: Bool) {
        let cached = lock.withLock { content as? Cache }
        if let cached, needed.allSatisfy({ cached.windows[$0] != nil }),
           !needsDisplays || !cached.displays.isEmpty {
            return (cached, true)
        }
        return (await refreshCache(managed: managed), false)
    }

    @available(macOS 14.0, *)
    private func refreshCache(managed: Set<WindowID>) async -> Cache? {
        let began = DispatchTime.now().uptimeNanoseconds
        do {
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let cache = Cache(content: fresh, managed: managed)
            lock.withLock { content = cache }
            let millis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
            GioLog.record(.debug, "snapshot shareable content fetch ms=\(Int(millis.rounded())) windows=\(cache.windows.count)")
            return cache
        } catch {
            GioLog.record(.warn, "snapshot shareable content failed: \(error.localizedDescription)")
            return nil
        }
    }

    @available(macOS 14.0, *)
    private static func captureWindow(_ window: SCWindow, size: CGSize, scale: CGFloat) async throws -> CGImage {
        try await captureWindow(window, pixels: snapshotPixelSize(points: size, scale: scale))
    }

    @available(macOS 14.0, *)
    private static func captureWindow(_ window: SCWindow, pixels: (width: Int, height: Int)) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.capturesShadowsOnly = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @available(macOS 14.0, *)
    private static func captureBackdrop(
        _ display: SCDisplay, excluding windows: [SCWindow], size: CGSize, scale: CGFloat
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let pixels = snapshotPixelSize(points: size, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// SM-09: samples of `image` as packed RGBA (alpha in the low byte) for
/// `snapshotLooksBlank`: a `grid` x `grid` interior grid plus `grid` samples
/// along each edge (title bars and borders are content). Every sample is a
/// draw of the whole image, or a one-pixel-wide crop of it, into a tiny
/// bitmap that it covers exactly (no interpolation, no partial coverage),
/// so the cost is independent of the image size.
func snapshotSamples(of image: CGImage, grid: Int = 5) -> [UInt32] {
    let width = image.width
    let height = image.height
    var samples = snapshotDrawSamples(image, width: grid, height: grid)
    for strip in [
        CGRect(x: 0, y: 0, width: width, height: 1), CGRect(x: 0, y: height - 1, width: width, height: 1),
    ] {
        if let edge = image.cropping(to: strip) {
            samples += snapshotDrawSamples(edge, width: grid, height: 1)
        }
    }
    for strip in [
        CGRect(x: 0, y: 0, width: 1, height: height), CGRect(x: width - 1, y: 0, width: 1, height: height),
    ] {
        if let edge = image.cropping(to: strip) {
            samples += snapshotDrawSamples(edge, width: 1, height: grid)
        }
    }
    return samples
}

/// SM-10: the dense confirmation of a blank verdict: the whole image drawn
/// into a 64x64 bitmap with nearest-neighbour sampling (4096 samples, one
/// draw, independent of the image size).
func snapshotDenseSamples(of image: CGImage, grid: Int = 64) -> [UInt32] {
    snapshotDrawSamples(image, width: grid, height: grid)
}

/// SM-29: the samples of one grown strip (`snapshotGrownStrips`, image
/// pixels, top-left origin) for `snapshotStripUnpainted`: the crop drawn
/// into at most 64x64 (nearest neighbour; every pixel of a small strip), in
/// sRGB like the fill it is compared with. Empty when the strip
/// is outside the image.
func snapshotStripSamples(of image: CGImage, in strip: CGRect, grid: Int = 64) -> [UInt32] {
    guard let crop = image.cropping(to: strip), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        return []
    }
    return snapshotDrawSamples(crop, width: min(crop.width, grid), height: min(crop.height, grid), space: space)
}

/// SM-30: the samples `snapshotContentFill` picks the fill from: the right
/// half of the capture (left sidebars keep their width when a window grows)
/// drawn into 32x64 (nearest neighbour, cost independent of the image
/// size), in sRGB like the overlay's colours.
func snapshotContentSamples(of image: CGImage) -> [UInt32] {
    let left = image.width / 2
    guard let half = image.cropping(to: CGRect(x: left, y: 0, width: image.width - left, height: image.height)),
          let space = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        return []
    }
    return snapshotDrawSamples(half, width: 32, height: 64, space: space)
}

/// SM-30: `snapshotSamples` of `region` of the image (pixels, top-left
/// origin, `snapshotRegionPixels`), for the stale-layout test. Empty when
/// the region is outside the image.
func snapshotRegionSamples(of image: CGImage, in region: CGRect) -> [UInt32] {
    guard let crop = image.cropping(to: region) else {
        return []
    }
    return snapshotSamples(of: crop)
}

private func snapshotDrawSamples(
    _ image: CGImage, width: Int, height: Int, space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
) -> [UInt32] {
    let count = width * height
    var pixels = [UInt8](repeating: 0, count: count * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else {
        return []
    }
    return (0..<count).map { index in
        let base = index * 4
        return UInt32(pixels[base]) << 24 | UInt32(pixels[base + 1]) << 16
            | UInt32(pixels[base + 2]) << 8 | UInt32(pixels[base + 3])
    }
}

/// SM-20: the app's windows in its `kAXWindowsAttribute` order, mapped to
/// managed ids by `identify` (unmanaged windows dropped). Apple documents
/// the attribute as "an array of the application's windows", no order;
/// front to back (z-order) is inferred. Never Gio's own pid (AX on
/// in-process elements crashes); a short messaging timeout so a hung app
/// costs the capture run at most that. No titles read.
public func axWindowOrder(pid: pid_t, identify: (AXUIElement) -> WindowID?) -> [WindowID] {
    guard isManageableProcess(pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier, onlyPID: nil) else {
        return []
    }
    let app = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetMessagingTimeout(app, AXWindowActuator.messagingTimeoutSeconds)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
          let elements = raw as? [AXUIElement]
    else {
        return []
    }
    return elements.compactMap(identify)
}
