import CoreGraphics
import Foundation
import GioCore

/// One window image to fly. Frames are Cocoa global coordinates. SM-27:
/// `image` is drawn at its own size, never scaled; `target` is the image of
/// the `to` size the layer shows from the first frame (SM-32; the same image
/// on a move, nil when none is cached).
public struct OverlayFlightItem: @unchecked Sendable {
    public let id: WindowID
    public let image: SnapshotFace<CGImage>
    public let target: SnapshotFace<CGImage>?
    public let from: CGRect
    public let to: CGRect
    public let velocity: CGPoint

    public init(
        id: WindowID, image: SnapshotFace<CGImage>, target: SnapshotFace<CGImage>?, from: CGRect, to: CGRect,
        velocity: CGPoint = .zero
    ) {
        self.id = id
        self.image = image
        self.target = target
        self.from = from
        self.to = to
        self.velocity = velocity
    }
}

/// The items of one display's overlay and the backdrop under them: the
/// display as captured without its managed windows (SM-09). SM-18: the
/// panel covers only `usableFrame` (menu bar and Dock excluded).
public struct OverlayFlight: @unchecked Sendable {
    public let displayFrame: CGRect
    public let usableFrame: CGRect
    public let backdrop: CGImage
    public let items: [OverlayFlightItem]

    public init(displayFrame: CGRect, usableFrame: CGRect, backdrop: CGImage, items: [OverlayFlightItem]) {
        self.displayFrame = displayFrame
        self.usableFrame = usableFrame
        self.backdrop = backdrop
        self.items = items
    }
}

/// SM-04/SM-08: the overlay that flies window images. Called on the session
/// queue; implementations hop to the main thread themselves.
public protocol OverlayPort: AnyObject {
    /// Put the overlay on screen with every layer at its start frame (prime).
    /// The implementation reports `SnapshotFlightController.primed` from
    /// main once the first frame is committed, or with `ok: false` when the
    /// overlay could not be shown.
    /// SM-16: `holes` are the target frames of the windows that fly without
    /// a layer; each display's backdrop is cut there so they show through.
    func beginFlight(
        token: Int, spring: SpringParameters, flights: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    )
    /// The real windows' writes are dispatched: start the springs.
    func flyFlight(token: Int)
    /// `holes` replaces the flight's whole hole set. SM-27: `images` holds,
    /// for each retargeted layer, the image of its new size when cached
    /// (the layer shows it at once, SM-32; without one, its closest image).
    func retargetFlight(
        token: Int, targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>],
        velocities: [WindowID: CGPoint], adds: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    )
    func trackFlight(token: Int, frames: [WindowID: CGRect])
    /// Remove the overlay at once.
    func endFlight()
    /// SM-30: fresh images of resized layers' landing sizes, captured
    /// mid-flight: each layer fades to its image on top (timed).
    func freshenFlight(token: Int, faces: [WindowID: SnapshotFace<CGImage>])
    /// SM-30: the hand-off of a flight with resized windows: the backdrop and
    /// every other layer go at once, the layers of `windows` fade out over
    /// the real windows in `duration`. A mouse down or a new flight removes
    /// them at once.
    func fadeOutFlight(windows: Set<WindowID>, duration: TimeInterval)
}

/// What `drive` decided for this animated pass.
public enum SnapshotDrive: Equatable, Sendable {
    /// The AX renderer carries the motion; the caller runs it now.
    case ax
    /// A primed overlay is flying (or being retargeted): the caller runs the
    /// instant pass now (one write per window under the overlay).
    case flying
    /// The overlay is being primed: the caller hands its instant pass and
    /// its AX fallback to `deferPass` and returns without writing anything.
    case priming
}

/// SM-04: the running overlay flight. With the snapshot renderer the real
/// windows get one write to their final frames under an overlay that draws
/// an opaque picture (SM-14: the panel itself is not opaque, so it does not
/// occlude them) and flies their cached images. SM-16: windows without an
/// image show through holes in that picture at their targets. SM-08 order: the session plans the flight and
/// primes the overlay (layers at their start frames, panel on screen); only
/// once main reports the prime does the session write the real windows, and
/// only then do the layers fly. SM-12: those writes are dispatched on the
/// per-app lanes without the session waiting (the overlay hides them); the
/// pass reports `passSettled` once dispatched and `collectWrites` folds the
/// outcome when the flight ends. The flight settles when its layers landed
/// AND the final exact pass settled (`SnapshotFlightGate` tokens). SM-14:
/// the overlay then stays up (nothing moving) until the windows that came
/// from off screen or changed size capture painted, at most
/// `SnapshotHandoff.cap` (`SnapshotHandoff`, `checkPaint`). SM-19: that
/// check starts `SnapshotHandoff.earlyLead` before the deadline the overlay
/// reports (`deadlineArmed`), so the overlay usually goes at the deadline,
/// and apps that painted `PaintTrustBook.cleanChecksToTrust` times in a row
/// are not checked. SM-29: a resized window is always checked, with the
/// size it grew from and its background (`SnapshotPaintProbe`), so a partly
/// painted or stale window holds the overlay too. SM-30: every resized
/// layer's window is captured again at its target size `firstDelay` after
/// its write (`SnapshotFreshTracker`, `captureFresh`); a fresh read goes to
/// the overlay (the layer fades to it) and into the cache; at the hand-off
/// the resized layers fade out over the real windows (`fadeOutFlight`)
/// instead of a hard cut. Session queue only;
/// `primed`/`deadlineArmed`/`layersFinished`/`aborted` are called from main
/// and hop on.
public final class SnapshotFlightController: @unchecked Sendable {
    public struct Context {
        public var displayFrames: () -> [CGRect]
        /// SM-18: each display's usable frame (menu bar and Dock excluded),
        /// index-aligned with `displayFrames`; the overlay panel covers it.
        public var usableFrames: () -> [CGRect]
        public var physicalFrames: () -> [WindowID: CGRect]
        public var isShuttingDown: () -> Bool
        /// FI-06: an action arrived during the motion (`ReflowCoalescer.takeAtTick`).
        public var takeCoalescedReflow: () -> Bool
        /// Put a coalesced request back (`ReflowCoalescer.request(motionActive: true)`).
        public var requestReflow: () -> Void
        public var performReflow: () -> Void
        /// SM-08: ring and dim the overlay draws for the windows landing at
        /// `targets` (the live rules, `FocusRingPublisher.flightDecorations`).
        public var decorations: ([WindowID: CGRect]) -> OverlayDecorations
        /// Publish the live ring and dim now (they return at the settle).
        public var publishIndicators: () -> Void
        /// SM-12: the real windows' writes under the overlay are dispatched
        /// without waiting; fold their outcome now (bounded wait). Called on
        /// every exit of a flight that may have written: settle, abort, end.
        public var collectWrites: () -> Void
        /// FI-05: schedule the render check when candidates are waiting.
        public var scheduleRenderCheck: () -> Void
        /// SM-14: tiny captures of these windows at their target frames and
        /// the blank test (SM-29: the size and grown-region tests of
        /// resized windows), off the session queue; `answer` may run on any
        /// thread. A window missing from the answer counts as `unknown`.
        public var checkPaint: (
            [WindowID: SnapshotPaintProbe], @escaping @Sendable (SnapshotPaintAnswer) -> Void
        ) -> Void
        /// SM-30: one full-resolution capture of a resized window at its
        /// target frame (`SnapshotFreshProbe`), off the session queue;
        /// `answer` (nil: not matched or not captured) may run on any thread.
        public var captureFresh: (
            WindowID, SnapshotFreshProbe<CGImage>, @escaping @Sendable (SnapshotFreshRead<CGImage>?) -> Void
        ) -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            displayFrames: @escaping () -> [CGRect], usableFrames: @escaping () -> [CGRect],
            physicalFrames: @escaping () -> [WindowID: CGRect],
            isShuttingDown: @escaping () -> Bool, takeCoalescedReflow: @escaping () -> Bool,
            requestReflow: @escaping () -> Void, performReflow: @escaping () -> Void,
            decorations: @escaping ([WindowID: CGRect]) -> OverlayDecorations,
            publishIndicators: @escaping () -> Void, collectWrites: @escaping () -> Void,
            scheduleRenderCheck: @escaping () -> Void,
            checkPaint: @escaping (
                [WindowID: SnapshotPaintProbe], @escaping @Sendable (SnapshotPaintAnswer) -> Void
            ) -> Void,
            captureFresh: @escaping (
                WindowID, SnapshotFreshProbe<CGImage>, @escaping @Sendable (SnapshotFreshRead<CGImage>?) -> Void
            ) -> Void,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.displayFrames = displayFrames
            self.usableFrames = usableFrames
            self.physicalFrames = physicalFrames
            self.isShuttingDown = isShuttingDown
            self.takeCoalescedReflow = takeCoalescedReflow
            self.requestReflow = requestReflow
            self.performReflow = performReflow
            self.decorations = decorations
            self.publishIndicators = publishIndicators
            self.collectWrites = collectWrites
            self.scheduleRenderCheck = scheduleRenderCheck
            self.checkPaint = checkPaint
            self.captureFresh = captureFresh
            self.log = log
            self.now = now
        }
    }

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
    /// SM-08: the token `beginFlight` was primed with, until main reports
    /// it; the pass waiting for that report (the latest one wins).
    private var primingToken: Int?
    private var pending: (writes: () -> Void, fallback: () -> Void)?
    /// SM-12: what the display presented, reported with the landing token.
    private var frames: FlightFrameStats?
    /// SM-14: every window's frame when it joined the flight (the first pass
    /// that involved it) and its latest target, for the paint-check set.
    private var origins: [WindowID: CGRect] = [:]
    private var targets: [WindowID: CGRect] = [:]
    /// SM-14: the hold at the deadline until the windows that came from off
    /// screen or changed size painted.
    private var handoff = SnapshotHandoff()
    /// SM-19: per-app paint statistics for the session.
    private var trust = PaintTrustBook()
    /// SM-16: windows visible at their target without a layer, at that
    /// target; the backdrop is cut there.
    private var holes: [WindowID: CGRect] = [:]
    /// SM-27: the size of the image each layer started with (its bottom
    /// face), for the resize mode a retarget logs.
    private var imageSizes: [WindowID: CGSize] = [:]
    /// SM-29: the content background of each layer's images (the target
    /// size's fill, else the start's; SM-30: the fresh image's once shown),
    /// for the grown-region test.
    private var backgrounds: [WindowID: ThemeColor] = [:]
    /// SM-30: the image each layer started with (the stale test of a
    /// shrinking window), how each resized layer draws its resize (the
    /// hand-off's resize line) and the fresh captures of the resized windows.
    private var startFaces: [WindowID: SnapshotFace<CGImage>] = [:]
    private var resizeModes: [WindowID: SnapshotResizeMode] = [:]
    private var fresh = SnapshotFreshTracker()
    private var gestureLost: (() -> Void)?
    private var heldFrames: [WindowID: CGRect] = [:]
    private var layerFrames: [WindowID: CGRect] = [:]
    private var flyAfterPass = false

    public init(
        context: Context, cache: SnapshotCacheRefresher, overlay: OverlayPort, scheduler: SessionScheduler
    ) {
        self.context = context
        self.cache = cache
        self.overlay = overlay
        self.scheduler = scheduler
    }

    /// A flight runs or its overlay is held for the hand-off (SM-14): either
    /// way the overlay is up, so ring, dim, cache refresh and render checks
    /// wait, and a key press retargets.
    public var isActive: Bool {
        gate.isActive || handoff.isHolding
    }

    /// Windows flying (or added to) the current flight.
    public var flyingWindows: Set<WindowID> {
        windows
    }

    /// Rapid actions during a flight: one merged retarget on the next turn
    /// of the session queue. Keys already queued merge into it; none waits a
    /// fixed delay (a 30 ms hold here added that much to every key pressed
    /// while the overlay was up).
    public func scheduleReflow() {
        guard !reflowScheduled else {
            return
        }
        reflowScheduled = true
        scheduler.async { [weak self] in
            guard let self else {
                return
            }
            reflowScheduled = false
            if !context.isShuttingDown(), context.takeCoalescedReflow() {
                context.performReflow()
            }
        }
    }

    /// `images`: the one lookup per window the plan was decided with. Every
    /// display of `items` and of `holes` gets a flight (SM-16: a display
    /// may show only holes).
    private func makeFlights(
        _ items: [SnapshotFlightItem], holes: [SnapshotHole] = [], images: [WindowID: SnapshotCacheUse<CGImage>],
        velocities: [WindowID: CGPoint] = [:], now: TimeInterval
    ) -> [OverlayFlight] {
        let frames = context.displayFrames()
        let usable = context.usableFrames()
        var byDisplay: [Int: [OverlayFlightItem]] = [:]
        for hole in holes where frames.indices.contains(hole.displayIndex) {
            byDisplay[hole.displayIndex, default: []] = []
        }
        for item in items {
            guard let use = images[item.id], frames.indices.contains(item.displayIndex) else {
                continue
            }
            cache.flies(item.id, use, at: now)
            imageSizes[item.id] = use.entry.frame.size
            backgrounds[item.id] = use.target?.fill ?? use.entry.fill
            startFaces[item.id] = use.entry.face
            resizeModes[item.id] = use.resize
            byDisplay[item.displayIndex, default: []].append(
                OverlayFlightItem(
                    id: item.id, image: use.entry.face, target: use.target?.face, from: item.from, to: item.to,
                    velocity: velocities[item.id] ?? .zero
                )
            )
        }
        return byDisplay.keys.sorted().compactMap { index in
            guard let backdrop = cache.backdrop(for: frames[index]) else {
                return nil
            }
            return OverlayFlight(
                displayFrame: frames[index], usableFrame: usable.indices.contains(index) ? usable[index] : frames[index],
                backdrop: backdrop, items: byDisplay[index]!
            )
        }
    }

    /// Decide snapshot vs AX for this motion and start (or retarget) the
    /// overlay flight. `.flying`: the caller runs the ordinary instant pass
    /// now (the real windows' one write under a primed overlay). `.priming`:
    /// the caller defers that pass with `deferPass`.
    public func drive(
        animations: [WindowAnimation], plans: [ParkingPlan], spring: SpringParameters, jumps: [WindowID: JumpPath] = [:],
        release: GestureRelease? = nil
    ) -> SnapshotDrive {
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
        var velocities: [WindowID: CGPoint] = [:]
        for animation in animations {
            starts[animation.id] = animation.from
            let heldLayer = layerFrames[animation.id] != nil
            if animation.velocity != .zero, !heldLayer {
                velocities[animation.id] = animation.velocity
            }
        }
        if let release {
            let layerStarts = starts.merging(layerFrames) { _, layer in layer }
            let settling = gestureSettleVelocities(
                windows: release.windows, velocity: release.velocity, from: layerStarts, to: targets
            )
            velocities.merge(settling) { _, released in released }
        }
        // MM-04 / MM-10: a far-side park (or a return from one) never flies
        // across the display: its layer slides out by (or in from) the shared
        // edge on its own display's overlay, which clips it there; the real
        // window jumps under the overlay.
        var pinned: [WindowID: Int] = [:]
        for (id, path) in jumps where targets[id] != nil {
            starts[id] = path.from
            targets[id] = path.to
            pinned[id] = screens.firstIndex(of: path.display)
            velocities[id] = nil
        }
        let now = context.now()
        // SM-31: windows macOS does not draw have nothing to fly: no layer,
        // no hole, never a miss.
        let undrawn = cache.undrawnWindows
        // SM-11: the image of the start size, or a fresh one of the other size.
        // SM-13: looked up once per window; the layers fly exactly that image.
        // SM-27: with the image of the target size the layer shows (SM-32).
        var images: [WindowID: SnapshotCacheUse<CGImage>] = [:]
        let usable: (WindowID) -> Bool = { [cache] id in
            if images[id] != nil {
                return true
            }
            guard let use = cache.flightImage(
                id, startFrame: starts[id] ?? targets[id], targetFrame: targets[id], at: now
            ) else {
                return false
            }
            images[id] = use
            return true
        }
        if isActive {
            if gestureLost != nil {
                gestureLost = nil
                layerFrames = [:]
                flyAfterPass = primingToken == nil
                startedAt = now
            }
            // SM-14: a retarget during the hold flies on; the hold is over.
            handoff.cancel()
            origins.merge(starts) { joined, _ in joined }
            let previousTargets = self.targets
            self.targets.merge(targets) { _, latest in latest }
            let plan = planSnapshotRetarget(
                active: ids, starts: starts, targets: targets, displays: screens,
                activeDisplays: displays, hasImage: usable, undrawn: undrawn, pinnedDisplays: pinned
            )
            ids.formUnion(plan.adds.map(\.id))
            windows.formUnion(plan.adds.map(\.id))
            // SM-16: the hole set follows the latest targets and layers.
            let previous = holes
            setHoles(snapshotHoles(
                layered: ids, targets: self.targets, displays: screens, activeDisplays: displays, undrawn: undrawn
            ))
            // SM-27: every retargeted layer shows the image of its new size
            // (SM-32: at once; the one it shows when the size stays).
            var faces: [WindowID: SnapshotFace<CGImage>] = [:]
            for (id, frame) in plan.retargets.sorted(by: { $0.key < $1.key }) {
                let from = previousTargets[id] ?? starts[id] ?? frame
                faces[id] = cache.retargetFace(
                    id, image: imageSizes[id] ?? from.size, from: from, to: frame, at: now
                )
                if snapshotResized(from: from.size, to: frame.size, tolerance: 2) {
                    resizeModes[id] = faces[id] != nil
                        ? .swap
                        : snapshotResizeMode(image: imageSizes[id] ?? from.size, target: nil, from: from.size, to: frame.size)
                }
            }
            let token = gate.retarget()
            let retargetVelocities = velocities.filter { plan.retargets[$0.key] != nil }
            overlay.retargetFlight(
                token: token, targets: plan.retargets, images: faces, velocities: retargetVelocities,
                adds: makeFlights(plan.adds, images: images, velocities: velocities, now: now),
                holes: holes, decorations: context.decorations(targets)
            )
            if primingToken == nil {
                // SM-30: the instant pass writes these windows now.
                followFresh(Set(plan.retargets.keys).union(plan.adds.map(\.id)), previousTargets: previousTargets)
            }
            if !plan.uncovered.isEmpty {
                // No image: written once under the overlay, shown through a
                // hole when visible at its target (SM-16).
                context.log(.debug, "snapshot retarget uncovered ids=\(plan.uncovered.count)")
                cache.schedule(delay: 0.05)
            }
            if holes != previous, !holes.isEmpty {
                context.log(.debug, snapshotHolesLine(count: holes.count))
            }
            return primingToken == nil ? .flying : .priming
        }
        let cache = cache
        let decision = planSnapshotFlight(
            starts: starts, targets: targets, displays: screens, hasImage: usable,
            backdropReady: { cache.backdrop(for: screens[$0]) != nil }, undrawn: undrawn, pinnedDisplays: pinned
        )
        switch decision {
        case .fallback(let reason, let missing):
            context.log(.info, snapshotFallbackLine(reason: reason, count: missing.count))
            // Next time the images are there.
            cache.schedule(delay: 0.05)
            return .ax
        case .snapshot(let items, let holes):
            imageSizes = [:]
            backgrounds = [:]
            startFaces = [:]
            resizeModes = [:]
            let flights = makeFlights(items, holes: holes, images: images, velocities: velocities, now: now)
            guard !flights.isEmpty else {
                return .ax
            }
            let ids = Set(items.map(\.id))
            let token = gate.begin()
            self.ids = ids
            windows = ids
            displays = Set(items.map(\.displayIndex)).union(holes.map(\.displayIndex))
            setHoles(holes)
            if !holes.isEmpty {
                context.log(.debug, snapshotHolesLine(count: holes.count))
            }
            startedAt = now
            cacheAgeMilliseconds = cache.cache.maxAgeMilliseconds(of: ids, now: now)
            origins = starts
            self.targets = targets
            primingToken = token
            pending = nil
            overlay.beginFlight(
                token: token, spring: spring, flights: flights, holes: self.holes,
                decorations: context.decorations(targets)
            )
            return .priming
        }
    }

    /// SM-08: the pass that waits for the prime. `writes` is the instant
    /// pass (one write per real window, then `passSettled`); `fallback` is
    /// the AX motion for the same pass, run when the overlay never made it
    /// to the screen. A later pass during the prime replaces both.
    public func deferPass(writes: @escaping () -> Void, fallback: @escaping () -> Void) {
        guard primingToken != nil else {
            return
        }
        pending = (writes, fallback)
    }

    public func holdGesture(
        frames: [WindowID: CGRect], display: CGRect, spring: SpringParameters, lost: @escaping () -> Void
    ) -> GestureTransport {
        let now = context.now()
        let index = context.displayFrames().firstIndex(of: display)
        let cache = cache
        let backdropReady = index != nil && cache.backdrop(for: display) != nil
        var images: [WindowID: SnapshotCacheUse<CGImage>] = [:]
        let transport = planGestureTransport(
            windows: Set(frames.keys), rendererUsable: cache.rendererUsable(), backdropReady: backdropReady,
            hasImage: { id in
                guard let use = cache.flightImage(id, startFrame: frames[id], targetFrame: frames[id], at: now) else {
                    return false
                }
                images[id] = use
                return true
            },
            undrawn: cache.undrawnWindows
        )
        context.log(.info, gestureTransportLine(transport))
        guard case .overlay(let layers) = transport, let index else {
            end()
            if case .accessibility(.cacheMiss, _) = transport {
                cache.schedule(delay: 0.05)
            }
            return transport
        }
        finishRunningFlight()
        imageSizes = [:]
        backgrounds = [:]
        startFaces = [:]
        resizeModes = [:]
        let items = layers.compactMap { id in
            frames[id].map { SnapshotFlightItem(id: id, from: $0, to: $0, displayIndex: index) }
        }
        let flights = makeFlights(items, images: images, now: now)
        let held = Set(items.map(\.id))
        let token = gate.begin()
        ids = held
        windows = held
        displays = [index]
        setHoles([])
        startedAt = now
        cacheAgeMilliseconds = cache.cache.maxAgeMilliseconds(of: held, now: now)
        origins = frames
        targets = frames
        primingToken = token
        pending = nil
        gestureLost = lost
        layerFrames = frames
        overlay.beginFlight(
            token: token, spring: spring, flights: flights, holes: holes, decorations: context.decorations(frames)
        )
        return transport
    }

    public func trackGesture(_ frames: [WindowID: CGRect]) {
        guard gestureLost != nil else {
            return
        }
        layerFrames.merge(frames) { _, latest in latest }
        guard primingToken == nil else {
            heldFrames.merge(frames) { _, latest in latest }
            return
        }
        overlay.trackFlight(token: gate.currentToken, frames: frames)
    }

    /// Main reports the prime of flight `token`: the overlay is on screen
    /// with every layer at its start frame (`ok`), or could not be shown.
    /// Then, in this order, the real windows are written and the layers
    /// fly; on failure the pass runs through AX with no write done yet.
    /// TG-07: a gesture hold instead takes the frames tracked meanwhile and
    /// waits for the release; a failed prime hands the gesture back.
    /// A reflow request that arrived while priming (a key press) survives
    /// the writes, which stop the AX motion and reset the coalescer: it is
    /// put back after them so the merged retarget flies to the newest layout.
    public func primed(_ token: Int, ok: Bool) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown(), gate.isActive, primingToken == token else {
                return
            }
            primingToken = nil
            let pass = pending
            pending = nil
            guard ok else {
                context.log(.info, snapshotFallbackLine(reason: .primeFailed, count: ids.count))
                let lost = gestureLost
                gate.abort()
                clear()
                overlay.endFlight()
                pass?.fallback()
                // The ring was hidden for the prime; the AX motion shows it
                // at the start frame like any AX pass.
                context.publishIndicators()
                lost?()
                return
            }
            if !heldFrames.isEmpty {
                overlay.trackFlight(token: gate.currentToken, frames: heldFrames)
                heldFrames = [:]
            }
            guard gestureLost == nil else {
                return
            }
            let retarget = context.takeCoalescedReflow()
            pass?.writes()
            if gate.isActive {
                overlay.flyFlight(token: gate.currentToken)
                if pass != nil {
                    // SM-30: the resized windows were just written.
                    followFresh(snapshotResizedWindows(starts: origins, targets: targets).intersection(ids))
                }
            }
            if retarget {
                context.requestReflow()
                scheduleReflow()
            }
        }
    }

    /// The final exact pass under the overlay is done; the flight settles
    /// once its layers landed too.
    public func passSettled() {
        if flyAfterPass {
            flyAfterPass = false
            overlay.flyFlight(token: gate.currentToken)
        }
        if gate.passSettled(gate.currentToken) {
            settle()
        }
    }

    /// SM-19: the overlay armed the landing of flight `token` at `deadline`
    /// (`now()` clock; at the fly and at every retarget while flying). One
    /// paint check of the hand-off set is scheduled `earlyLead` before it;
    /// a retarget, an abort or an end supersedes the token and the check
    /// no-ops. Called from the main thread.
    public func deadlineArmed(_ token: Int, at deadline: TimeInterval) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown(), gate.isActive, token == gate.currentToken else {
                return
            }
            let now = context.now()
            let delay = SnapshotHandoff.earlyCheckTime(deadline: deadline, now: now) - now
            scheduler.asyncAfter(delay) { [weak self] in
                guard let self, !context.isShuttingDown(), gate.isActive, token == gate.currentToken,
                      let (check, step) = handoff.prepare(windows: paintCheckWindows().windows)
                else {
                    return
                }
                advanceHandoff(step, token: check)
            }
        }
    }

    /// Overlay layers of flight `token` landed (called from the main thread)
    /// with the frames the display presented meanwhile (SM-12, nil when not
    /// measured).
    public func layersFinished(_ token: Int, frames: FlightFrameStats? = nil) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown() else {
                return
            }
            if gate.isActive, token == gate.currentToken {
                self.frames = frames
            }
            if gate.layersFinished(token) {
                settle()
            }
        }
    }

    /// The overlay came down on its own (watchdog, mouse down): treat it as a
    /// settle. A pass still waiting for the prime runs through AX instead.
    /// Called from the main thread.
    public func aborted(_ reason: SnapshotAbortReason) {
        scheduler.async { [weak self] in
            guard let self, !context.isShuttingDown(), isActive else {
                return
            }
            context.log(reason.logLevel, snapshotAbortLine(reason: reason))
            let pass = takePending()
            let lost = gestureLost
            handoff.cancel()
            gate.abort()
            clear()
            context.collectWrites()
            context.publishIndicators()
            context.scheduleRenderCheck()
            cache.schedule()
            pass?.fallback()
            lost?()
        }
    }

    /// Screens changed under the flight: come down (the caller relayouts).
    public func abortForDisplayChange() {
        if isActive {
            context.log(.info, snapshotAbortLine(reason: .displayChange))
            end()
        }
    }

    /// Abandon a flight without the normal settle (shutdown, display change,
    /// a non-animated pass); a pass waiting for the prime is dropped, the
    /// caller relayouts or restores.
    public func end() {
        guard isActive else {
            return
        }
        _ = takePending()
        let lost = context.isShuttingDown() ? nil : gestureLost
        handoff.cancel()
        gate.abort()
        context.collectWrites()
        clear()
        overlay.endFlight()
        context.publishIndicators()
        lost?()
    }

    private func finishRunningFlight() {
        guard isActive else {
            return
        }
        _ = takePending()
        handoff.cancel()
        gate.abort()
        context.collectWrites()
        clear()
    }

    /// Layers landed and the real windows' writes were dispatched: their
    /// outcome is folded (SM-12). SM-14: the overlay is then held until the
    /// windows that came from off screen or changed size painted (or the
    /// cap); `handOver` brings it down.
    private func settle() {
        let duration = context.now() - startedAt
        context.log(
            .info, MotionSummary.snapshotFlight(windows: windows.count, duration: duration, frames: frames).logLine
        )
        context.log(
            .info,
            snapshotFlightLine(
                layers: ids.count, cacheAgeMilliseconds: cacheAgeMilliseconds, duration: duration, frames: frames
            )
        )
        context.collectWrites()
        let check = paintCheckWindows()
        let (token, step) = handoff.begin(windows: check.windows, resized: check.resized, now: context.now())
        if handoff.isHolding {
            scheduler.asyncAfter(SnapshotHandoff.cap) { [weak self] in
                guard let self, !context.isShuttingDown(),
                      let summary = handoff.capReached(token, now: context.now())
                else {
                    return
                }
                handOver(summary)
            }
        }
        advanceHandoff(step, token: token)
    }

    /// The windows whose paint the hand-off waits for. SM-16: the hole
    /// windows came into view through their holes (always checked); SM-19:
    /// the others of trusted apps are skipped; SM-29: except resized ones
    /// (`resized`: those of `windows` that changed size).
    private func paintCheckWindows() -> (windows: Set<WindowID>, resized: Set<WindowID>) {
        let screens = context.displayFrames()
        let candidates = snapshotPaintCheckWindows(
            starts: origins, targets: targets, screens: screens,
            covered: displays.sorted().filter { screens.indices.contains($0) }.map { screens[$0] }
        ).union(holes.keys)
        let resized = snapshotResizedWindows(starts: origins, targets: targets).intersection(candidates)
        let windows = trust.windowsToCheck(candidates, always: resized.union(holes.keys))
        return (windows, resized)
    }

    private func advanceHandoff(_ step: SnapshotHandoff.Step, token: Int) {
        switch step {
        case .check(let ids):
            checkPaint(ids, token: token)
        case .recheck(let ids, let delay):
            scheduler.asyncAfter(delay) { [weak self] in
                guard let self, !context.isShuttingDown(), handoff.isCurrent(token) else {
                    return
                }
                checkPaint(ids, token: token)
            }
        case .release(let summary):
            handOver(summary)
        case .awaiting:
            break
        }
    }

    /// The capture runs off the queue; its answer hops back on. SM-29: a
    /// resized window's probe carries the size it grew from and its
    /// background.
    private func checkPaint(_ ids: Set<WindowID>, token: Int) {
        var probes: [WindowID: SnapshotPaintProbe] = [:]
        for id in ids {
            guard let frame = targets[id] else {
                continue
            }
            let start = origins[id].map(\.size).flatMap { snapshotResized(from: $0, to: frame.size) ? $0 : nil }
            probes[id] = SnapshotPaintProbe(frame: frame, resizedFrom: start, background: backgrounds[id])
        }
        context.checkPaint(probes) { [weak self] answer in
            self?.scheduler.async { [weak self] in
                guard let self, !context.isShuttingDown(), handoff.isCurrent(token) else {
                    return
                }
                trust.record(answer.verdicts.filter { ids.contains($0.key) })
                guard let step = handoff.record(
                    token, verdicts: answer.verdicts, samples: answer.samples, now: context.now()
                ) else {
                    return
                }
                advanceHandoff(step, token: token)
            }
        }
    }

    // MARK: SM-30 fresh images

    /// The writes of `candidates` were just dispatched: a new series for each
    /// whose size differs from its flight start, unless its size did not
    /// change since `previousTargets` (a move keeps its series); a window
    /// back at its start size needs none.
    private func followFresh(_ candidates: Set<WindowID>, previousTargets: [WindowID: CGRect] = [:]) {
        let now = context.now()
        for id in candidates.intersection(ids).sorted() {
            guard let target = targets[id], let origin = origins[id] else {
                continue
            }
            guard snapshotResized(from: origin.size, to: target.size) else {
                fresh.forget(id)
                continue
            }
            if let previous = previousTargets[id], !snapshotResized(from: previous.size, to: target.size),
               fresh.outcome(id) != nil {
                continue
            }
            let token = fresh.start(id, now: now)
            scheduler.asyncAfter(SnapshotFreshTracker.firstDelay) { [weak self] in
                self?.captureFresh(id, token: token)
            }
        }
    }

    /// One capture of the series `token` of `id`, at its current target.
    private func captureFresh(_ id: WindowID, token: Int) {
        guard !context.isShuttingDown(), isActive, let target = targets[id], fresh.capture(id, token: token) else {
            return
        }
        let resizedFrom = origins[id].map(\.size).flatMap { snapshotResized(from: $0, to: target.size) ? $0 : nil }
        let start = startFaces[id].flatMap { snapshotFreshRegion(start: $0.size, target: target.size) != nil ? $0 : nil }
        let probe = SnapshotFreshProbe(
            paint: SnapshotPaintProbe(frame: target, resizedFrom: resizedFrom, background: backgrounds[id]),
            start: start, cached: cache.cache.entry(id, matching: target)?.face
        )
        context.captureFresh(id, probe) { [weak self] read in
            self?.scheduler.async { [weak self] in
                self?.freshAnswered(id, token: token, size: target.size, read: read)
            }
        }
    }

    /// A fresh read of `id` (captured for a target of `size`) came back.
    private func freshAnswered(_ id: WindowID, token: Int, size: CGSize, read: SnapshotFreshRead<CGImage>?) {
        guard !context.isShuttingDown(), isActive,
              let step = fresh.record(
                  id, token: token, verdict: snapshotFreshVerdict(read, target: size), samples: read?.samples ?? [],
                  now: context.now()
              )
        else {
            return
        }
        switch step {
        case .apply:
            guard let read, let target = targets[id] else {
                return
            }
            cache.storeFresh(id, CapturedImage(image: read.image, frame: target, fill: read.fill))
            if let fill = read.fill {
                backgrounds[id] = fill
            }
            overlay.freshenFlight(
                token: gate.currentToken, faces: [id: SnapshotFace(image: read.image, size: target.size, fill: read.fill)]
            )
        case .retry(let delay):
            scheduler.asyncAfter(delay) { [weak self] in
                self?.captureFresh(id, token: token)
            }
        case .stop:
            break
        }
    }

    /// The live ring and dim go up (same geometry as the overlay's), then
    /// the overlay comes down, then the render check and the image refresh.
    /// SM-30: the resized layers fade out over the real windows instead
    /// (`snapshotHandoffFading`); each logs how it resized and when its
    /// fresh image came.
    private func handOver(_ summary: SnapshotHandoffSummary) {
        let resized = snapshotResizedWindows(starts: origins, targets: targets).intersection(ids)
        for id in resized.sorted() {
            guard let origin = origins[id], let target = targets[id],
                  let mode = resizeModes[id] ?? snapshotResizeMode(
                      image: imageSizes[id] ?? origin.size, target: nil, from: origin.size, to: target.size
                  )
            else {
                continue
            }
            let outcome = fresh.outcome(id) ?? SnapshotFreshOutcome(milliseconds: nil, attempts: 0, last: nil)
            context.log(.debug, snapshotResizeOutcomeLine(id, mode: mode, fresh: outcome))
        }
        let fading = snapshotHandoffFading(resized: resized, layered: ids)
        var summary = summary
        if !fading.isEmpty {
            summary.fadeMilliseconds = Int((snapshotHandoffFadeDuration * 1000).rounded())
        }
        context.log(summary.logLevel, summary.logLine)
        clear()
        context.publishIndicators()
        if fading.isEmpty {
            overlay.endFlight()
        } else {
            overlay.fadeOutFlight(windows: fading, duration: snapshotHandoffFadeDuration)
        }
        context.scheduleRenderCheck()
        cache.schedule()
    }

    private func takePending() -> (writes: () -> Void, fallback: () -> Void)? {
        primingToken = nil
        defer { pending = nil }
        return pending
    }

    private func clear() {
        ids = []
        displays = []
        windows = []
        frames = nil
        origins = [:]
        targets = [:]
        holes = [:]
        backgrounds = [:]
        startFaces = [:]
        resizeModes = [:]
        fresh.removeAll()
        gestureLost = nil
        heldFrames = [:]
        layerFrames = [:]
        flyAfterPass = false
    }

    private func setHoles(_ next: [SnapshotHole]) {
        holes = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0.frame) })
    }
}
