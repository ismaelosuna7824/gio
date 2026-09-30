import CoreGraphics
import Foundation
import GioCore

/// One window image to fly. Frames are Cocoa global coordinates.
public struct OverlayFlightItem: @unchecked Sendable {
    public let id: WindowID
    public let image: CGImage
    public let from: CGRect
    public let to: CGRect

    public init(id: WindowID, image: CGImage, from: CGRect, to: CGRect) {
        self.id = id
        self.image = image
        self.from = from
        self.to = to
    }
}

/// The items of one display's overlay.
public struct OverlayFlight: @unchecked Sendable {
    public let displayFrame: CGRect
    public let items: [OverlayFlightItem]

    public init(displayFrame: CGRect, items: [OverlayFlightItem]) {
        self.displayFrame = displayFrame
        self.items = items
    }
}

/// SM-04: the overlay that flies window images. Called on the session
/// queue; implementations hop to the main thread themselves.
public protocol OverlayPort: AnyObject {
    func beginFlight(token: Int, spring: SpringParameters, flights: [OverlayFlight])
    func retargetFlight(token: Int, targets: [WindowID: CGRect], adds: [OverlayFlight])
    func endFlight(fadeOut: Bool)
    /// A wallpaper backdrop is ready for the display with this frame (any thread).
    func hasBackdrop(for displayFrame: CGRect) -> Bool
}

/// SM-04: the running overlay flight. With the snapshot renderer the real
/// windows get one write to their final frames under an opaque overlay that
/// flies their cached images; the flight settles when its layers landed AND
/// the final exact pass settled (`SnapshotFlightGate` tokens). Session queue
/// only; `layersFinished`/`aborted` are called from main and hop on.
public final class SnapshotFlightController: @unchecked Sendable {
    public struct Context {
        public var displayFrames: () -> [CGRect]
        public var physicalFrames: () -> [WindowID: CGRect]
        public var isShuttingDown: () -> Bool
        /// FI-06: an action arrived during the motion (`ReflowCoalescer.takeAtTick`).
        public var takeCoalescedReflow: () -> Bool
        public var performReflow: () -> Void
        public var publishFocusRing: () -> Void
        /// FI-05: schedule the render check when candidates are waiting.
        public var scheduleRenderCheck: () -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            displayFrames: @escaping () -> [CGRect], physicalFrames: @escaping () -> [WindowID: CGRect],
            isShuttingDown: @escaping () -> Bool, takeCoalescedReflow: @escaping () -> Bool,
            performReflow: @escaping () -> Void, publishFocusRing: @escaping () -> Void,
            scheduleRenderCheck: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.displayFrames = displayFrames
            self.physicalFrames = physicalFrames
            self.isShuttingDown = isShuttingDown
            self.takeCoalescedReflow = takeCoalescedReflow
            self.performReflow = performReflow
            self.publishFocusRing = publishFocusRing
            self.scheduleRenderCheck = scheduleRenderCheck
            self.log = log
            self.now = now
        }
    }

    /// An overlay flight has no tick: one merged retarget shortly after a burst.
    public static let retargetDelay: TimeInterval = 0.03

    private let context: Context
    private let scheduler: SessionScheduler
    private let cache: SnapshotCacheRefresher
    private let overlay: OverlayPort
    private var gate = SnapshotFlightGate()
    private var ids: Set<WindowID> = []
    private var displays: Set<Int> = []
    private var startedAt: TimeInterval = 0
    private var windows: Set<WindowID> = []
    private var cacheAgeMilliseconds = 0
    private var reflowScheduled = false

    public init(
        context: Context, cache: SnapshotCacheRefresher, overlay: OverlayPort, scheduler: SessionScheduler
    ) {
        self.context = context
        self.cache = cache
        self.overlay = overlay
        self.scheduler = scheduler
    }

    public var isActive: Bool {
        gate.isActive
    }

    /// Windows flying (or added to) the current flight.
    public var flyingWindows: Set<WindowID> {
        windows
    }

    /// Rapid actions during a flight: one merged retarget shortly after.
    public func scheduleReflow() {
        guard !reflowScheduled else {
            return
        }
        reflowScheduled = true
        scheduler.asyncAfter(Self.retargetDelay) { [weak self] in
            guard let self else {
                return
            }
            reflowScheduled = false
            if !context.isShuttingDown(), context.takeCoalescedReflow() {
                context.performReflow()
            }
        }
    }

    private func makeFlights(_ items: [SnapshotFlightItem]) -> [OverlayFlight] {
        let frames = context.displayFrames()
        var byDisplay: [Int: [OverlayFlightItem]] = [:]
        for item in items {
            guard let entry = cache.cache.entry(item.id), frames.indices.contains(item.displayIndex) else {
                continue
            }
            byDisplay[item.displayIndex, default: []].append(
                OverlayFlightItem(id: item.id, image: entry.image, from: item.from, to: item.to)
            )
        }
        return byDisplay.keys.sorted().map { OverlayFlight(displayFrame: frames[$0], items: byDisplay[$0]!) }
    }

    /// Decide snapshot vs AX for this motion and start (or retarget) the
    /// overlay flight. True when the overlay carries the motion. The caller
    /// then runs the ordinary instant pass, which is the real windows' one
    /// write.
    public func drive(animations: [WindowAnimation], plans: [ParkingPlan], spring: SpringParameters) -> Bool {
        let screens = context.displayFrames()
        var targets: [WindowID: CGRect] = [:]
        for plan in plans {
            for (id, frame) in plan.visible where plan.parked[id] == nil {
                targets[id] = frame
            }
            for (id, parked) in plan.parked {
                targets[id] = parked.frame
            }
        }
        var starts = context.physicalFrames().filter { targets[$0.key] != nil }
        for animation in animations {
            starts[animation.id] = animation.from
        }
        let now = context.now()
        let snapshotCache = cache.cache
        let usable: (WindowID) -> Bool = { id in
            guard let entry = snapshotCache.entry(id) else {
                return false
            }
            return snapshotEntryUsable(entry, currentFrame: starts[id] ?? targets[id] ?? entry.frame, now: now)
        }
        if gate.isActive {
            let plan = planSnapshotRetarget(
                active: ids, starts: starts, targets: targets, displays: screens,
                activeDisplays: displays, hasImage: usable
            )
            let token = gate.retarget()
            overlay.retargetFlight(token: token, targets: plan.retargets, adds: makeFlights(plan.adds))
            ids.formUnion(plan.adds.map(\.id))
            windows.formUnion(plan.adds.map(\.id))
            cache.touch(plan.adds.map(\.id), at: now)
            if !plan.uncovered.isEmpty {
                // No image: written once under the overlay, revealed when it ends.
                context.log(.debug, "snapshot retarget uncovered ids=\(plan.uncovered.count)")
                cache.schedule(delay: 0.05)
            }
            return true
        }
        let overlay = overlay
        let decision = planSnapshotFlight(
            starts: starts, targets: targets, displays: screens, hasImage: usable,
            backdropReady: { overlay.hasBackdrop(for: screens[$0]) }
        )
        switch decision {
        case .fallback(let reason, let missing):
            context.log(.info, snapshotFallbackLine(reason: reason, count: missing.count))
            // Next time the images are there.
            cache.schedule(delay: 0.05)
            return false
        case .snapshot(let items):
            let flights = makeFlights(items)
            guard !flights.isEmpty else {
                return false
            }
            let ids = Set(items.map(\.id))
            let token = gate.begin()
            self.ids = ids
            windows = ids
            displays = Set(items.map(\.displayIndex))
            startedAt = now
            cacheAgeMilliseconds = cache.cache.maxAgeMilliseconds(of: ids, now: now)
            cache.touch(ids, at: now)
            overlay.beginFlight(token: token, spring: spring, flights: flights)
            return true
        }
    }

    /// The final exact pass under the overlay is done; the flight settles
    /// once its layers landed too.
    public func passSettled() {
        if gate.passSettled(gate.currentToken) {
            settle()
        }
    }

    /// Overlay layers of flight `token` landed (called from the main thread).
    public func layersFinished(_ token: Int) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown() else {
                return
            }
            if gate.layersFinished(token) {
                settle()
            }
        }
    }

    /// The overlay came down on its own (watchdog, mouse down): treat it as a
    /// settle without the fade. Called from the main thread.
    public func aborted(_ reason: SnapshotAbortReason) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown(), gate.isActive else {
                return
            }
            context.log(reason.logLevel, snapshotAbortLine(reason: reason))
            gate.abort()
            clear()
            context.publishFocusRing()
            context.scheduleRenderCheck()
            cache.schedule()
        }
    }

    /// Screens changed under the flight: come down (the caller relayouts).
    public func abortForDisplayChange() {
        if gate.isActive {
            context.log(.info, snapshotAbortLine(reason: .displayChange))
            end(fadeOut: false)
        }
    }

    /// Abandon a flight without the normal settle (fallback to AX, shutdown).
    public func end(fadeOut: Bool) {
        guard gate.isActive else {
            return
        }
        gate.abort()
        clear()
        overlay.endFlight(fadeOut: fadeOut)
        context.publishFocusRing()
    }

    /// Layers landed and the real windows settled: remove the overlay, show
    /// the ring, verify the render and refresh the image cache in the
    /// background.
    private func settle() {
        let duration = context.now() - startedAt
        overlay.endFlight(fadeOut: true)
        context.log(
            .info,
            MotionSummary(
                windows: windows.count, frames: 0, dropped: 0, duration: duration, slowest: nil,
                curve: "spring", renderer: "snapshot"
            ).logLine
        )
        context.log(
            .info,
            snapshotFlightLine(layers: ids.count, cacheAgeMilliseconds: cacheAgeMilliseconds, duration: duration)
        )
        clear()
        context.publishFocusRing()
        context.scheduleRenderCheck()
        cache.schedule()
    }

    private func clear() {
        ids = []
        displays = []
        windows = []
    }
}
