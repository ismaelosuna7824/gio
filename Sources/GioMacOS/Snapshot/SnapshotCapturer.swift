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
// compared.
//
// Deployment target is macOS 13 but `SCScreenshotManager` needs macOS 14:
// on 13 every window is reported as a failed miss and callers fall back to
// the Accessibility motion.

/// One captured window image. `frame` is the Cocoa frame the window had when
/// requested and `scale` the backing scale the image was rendered at.
public struct CapturedSnapshot: @unchecked Sendable {
    public let id: WindowID
    public let image: CGImage
    public let frame: CGRect
    public let scale: CGFloat
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
    public var displays: [SnapshotDisplay]
    /// Height of the primary display, for the top-left to Cocoa flip.
    public var primaryDisplayHeight: CGFloat
    public var includeBackdrop: Bool
    public var budgetMilliseconds: Int
    /// Debug measurement: a generous cap instead of the budget, and the
    /// result carries a latency breakdown (Diagnostics "Test snapshot capture").
    public var measure: Bool

    /// Cap used in measure mode so slow captures still report their latency.
    public static let measureCapMilliseconds = 2000

    public init(
        windows: [WindowID: CGRect], displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat,
        includeBackdrop: Bool = true, budgetMilliseconds: Int = SnapshotBudget.defaultMilliseconds,
        measure: Bool = false
    ) {
        self.windows = windows
        self.displays = displays
        self.primaryDisplayHeight = primaryDisplayHeight
        self.includeBackdrop = includeBackdrop
        self.budgetMilliseconds = budgetMilliseconds
        self.measure = measure
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

    public init(ownPid: pid_t = getpid()) {
        self.ownPid = ownPid
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
                    elapsedMilliseconds: 0
                ),
                measurement: nil
            )
        }
        GioLog.record(.info, result.summary.logLine)
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

    // MARK: - ScreenCaptureKit (macOS 14+)

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

        func complete(window id: WindowID, image: CGImage?) {
            lock.lock()
            if !finished {
                if let image {
                    images[id] = image
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
            images: [WindowID: CGImage], failed: Set<WindowID>, backdrops: [UInt32: CGImage]
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (images, failed, backdropImages)
        }
    }

    @available(macOS 14.0, *)
    private func captureSCK(_ request: SnapshotCaptureRequest, start: UInt64) async -> SnapshotCaptureResult {
        let ids = request.windows.keys.sorted()
        let pids = Set(ids.map(\.pid))
        let candidates = windowServerSnapshotCandidates(pids: pids, displayHeight: request.primaryDisplayHeight)
        let matches = matchSnapshotCandidates(managed: request.windows, candidates: candidates)
        let backdropDisplays = request.includeBackdrop
            ? displaysNeedingBackdrop(windowFrames: Array(request.windows.values), displays: request.displays)
            : []
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
                    request: request, ids: ids, matches: matches, backdropDisplays: backdropDisplays,
                    collector: collector, timings: timings
                )
            }
        }
        let out = collector.snapshot()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        var snapshots: [WindowID: CapturedSnapshot] = [:]
        for (id, image) in out.images {
            let frame = request.windows[id] ?? .zero
            snapshots[id] = CapturedSnapshot(
                id: id, image: image, frame: frame, scale: backingScale(for: frame, displays: request.displays)
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
        let summary = makeSnapshotSummary(
                requested: ids, matches: matches, captured: Set(snapshots.keys), failed: out.failed,
                backdropsRequested: backdropDisplays.count, backdropsCaptured: backdrops.count,
                elapsedMilliseconds: elapsed
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
        backdropDisplays: [UInt32], collector: Collector,
        timings: Timings
    ) async {
        let managed = Set(ids)
        let needed = Set(ids.compactMap { id -> UInt32? in
            if case .matched(let windowID)? = matches[id] { return windowID }
            return nil
        })
        let fetchBegan = DispatchTime.now().uptimeNanoseconds
        let lookup = await ensureCache(managed: managed, needed: needed, needsDisplays: !backdropDisplays.isEmpty)
        timings.setFetch(Double(DispatchTime.now().uptimeNanoseconds - fetchBegan) / 1_000_000, cached: lookup.cached)
        guard let cache = lookup.cache, !collector.isFinished
        else {
            collector.failAll(ids.filter { if case .matched? = matches[$0] { return true } else { return false } })
            return
        }
        // Gio's own windows are excluded from every backdrop, next to the animated ones.
        let own = cache.windows.values.map {
            SnapshotCandidate(windowID: $0.windowID, pid: $0.owningApplication?.processID ?? 0, frame: .zero)
        }
        let excludedIDs = snapshotExclusions(candidates: own, animated: needed, ownPid: ownPid)
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
            let scale = backingScale(for: frame, displays: request.displays)
            let boxed = Box(value: window)
            Task {
                let began = DispatchTime.now().uptimeNanoseconds
                let image = try? await Self.captureWindow(boxed.value, size: frame.size, scale: scale)
                let millis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                GioLog.record(.debug, "snapshot window id=\(job.id.pid):\(job.id.elementID) ms=\(Int(millis.rounded())) ok=\(image != nil)")
                if image != nil {
                    timings.addWindow(millis)
                }
                collector.complete(window: job.id, image: image)
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
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixels = snapshotPixelSize(points: size, scale: scale)
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
