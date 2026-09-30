import AppKit
import GioCore
import ImageIO
import QuartzCore

// SM-03: GPU snapshot overlay. Main thread only (AppKit + Core Animation).
// Compile-checked; every decision it takes (coordinates, spring mapping,
// retarget start, layer diff, watchdog) is pure and tested in GioCore
// (`OverlayGeometry`). During a flight Gio does no per-frame work: Core
// Animation runs the springs on the render server.
//
// Window levels (higher is in front): app windows `.normal` = 0, this overlay
// `.normal + 1` = 1, the focus ring `.floating` = 3 (so the ring stays visible
// above the images), Dock 20, menus 24 and above. The overlay is therefore in
// front of ordinary windows but behind the ring, the Dock and the menu bar.

/// One window image to fly. Frames are Cocoa global coordinates.
public struct SnapshotOverlayItem: @unchecked Sendable {
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
public struct SnapshotDisplayFlight: @unchecked Sendable {
    public let displayFrame: CGRect
    public let items: [SnapshotOverlayItem]

    public init(displayFrame: CGRect, items: [SnapshotOverlayItem]) {
        self.displayFrame = displayFrame
        self.items = items
    }
}

/// The overlay window: never key, never main, never activating, click-through.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class OverlayRootView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Wallpaper images per display, decoded off the main thread and read from
/// any thread (the session queue asks `hasImage` before choosing a renderer).
public final class WallpaperCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]

    public init() {}

    static func key(_ frame: CGRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
    }

    public func hasImage(for displayFrame: CGRect) -> Bool {
        lock.withLock { images[Self.key(displayFrame)] != nil }
    }

    func image(for displayFrame: CGRect) -> CGImage? {
        lock.withLock { images[Self.key(displayFrame)] }
    }

    func store(_ image: CGImage?, for displayFrame: CGRect) {
        lock.withLock { images[Self.key(displayFrame)] = image }
    }

    func retain(only frames: [CGRect]) {
        let keep = Set(frames.map(Self.key))
        lock.withLock { images = images.filter { keep.contains($0.key) } }
    }
}

/// One display's overlay: an opaque panel with the wallpaper and one layer
/// per flying window.
@MainActor
final class SnapshotOverlay {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    static let cornerRadius: CGFloat = 10
    static let fadeDuration: TimeInterval = 0.06

    let displayFrame: CGRect
    private let panel: OverlayPanel
    private let root: OverlayRootView
    private let backdrop = CALayer()
    private var layers: [WindowID: CALayer] = [:]
    private var models: [WindowID: LayerGeometry] = [:]
    private var generation = 0
    private var fadeGeneration = 0
    var spring: SpringParameters

    var ids: Set<WindowID> { Set(layers.keys) }

    init(displayFrame: CGRect, spring: SpringParameters) {
        self.displayFrame = displayFrame
        self.spring = spring
        panel = OverlayPanel(
            contentRect: displayFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        root = OverlayRootView(frame: CGRect(origin: .zero, size: displayFrame.size))
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.frame = root.bounds
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.layer?.addSublayer(backdrop)
        panel.contentView = root
    }

    // MARK: API

    /// Show the overlay: wallpaper, then one layer per item flying from its
    /// start frame to its target.
    /// Returns the largest travel (points) of any layer, for the deadline.
    @discardableResult
    func begin(backdropImage: CGImage?, items: [SnapshotOverlayItem]) -> Double {
        fadeGeneration += 1
        panel.alphaValue = 1
        panel.setFrame(displayFrame, display: false)
        root.frame = CGRect(origin: .zero, size: displayFrame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = root.bounds
        backdrop.contents = backdropImage
        CATransaction.commit()
        removeAllLayers()
        panel.orderFrontRegardless()
        return fly(targets: [:], adding: items, prime: true)
    }

    /// Retarget layers already flying (from their presentation values) and
    /// add layers for windows that were not part of the flight. Returns the
    /// largest travel. The end of the flight is the controller's deadline,
    /// not Core Animation completion.
    @discardableResult
    func retarget(targets: [WindowID: CGRect], adding items: [SnapshotOverlayItem]) -> Double {
        fly(targets: targets, adding: items, prime: false)
    }

    /// Remove the overlay, fading it out (~60 ms) or at once.
    func end(fadeOut: Bool) {
        generation += 1
        fadeGeneration += 1
        let token = fadeGeneration
        guard fadeOut, panel.isVisible else {
            teardown()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == token else {
                    return
                }
                self.teardown()
            }
        }
    }

    func close() {
        generation += 1
        fadeGeneration += 1
        teardown()
        panel.close()
    }

    // MARK: Flight

    /// `prime`: a fresh overlay. The layers are first attached at their start
    /// frames and the panel is displayed and flushed to the render server, so
    /// the first frame shows the start positions; only then the springs are
    /// added (animations on layers that are not rendered yet complete at once,
    /// the cause of the 6-83 ms flights).
    private func fly(targets: [WindowID: CGRect], adding items: [SnapshotOverlayItem], prime: Bool) -> Double {
        generation += 1
        let mapping = overlaySpring(spring)
        var travel = 0.0
        var starts: [(CALayer, WindowID, LayerGeometry, LayerGeometry)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, frame) in targets.sorted(by: { $0.key < $1.key }) {
            guard let layer = layers[id], let model = models[id] else {
                continue
            }
            let next = overlayLayerGeometry(frame: frame, in: displayFrame, flipped: root.isFlipped)
            let start = retargetStart(
                presentation: (layer.presentation()).map { LayerGeometry(position: $0.position, bounds: $0.bounds) },
                model: model
            )
            starts.append((layer, id, start, next))
        }
        for item in items {
            let layer = makeLayer(item.image)
            let start = overlayLayerGeometry(frame: item.from, in: displayFrame, flipped: root.isFlipped)
            let end = overlayLayerGeometry(frame: item.to, in: displayFrame, flipped: root.isFlipped)
            layers[item.id]?.removeFromSuperlayer()
            layer.position = start.position
            layer.bounds = start.bounds
            root.layer?.addSublayer(layer)
            layers[item.id] = layer
            starts.append((layer, item.id, start, end))
        }
        CATransaction.commit()
        if prime {
            panel.orderFrontRegardless()
            root.displayIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
        }
        CATransaction.begin()
        for (layer, id, start, end) in starts {
            travel = max(travel, animate(layer, from: start, to: end, spring: mapping))
            models[id] = end
        }
        CATransaction.commit()
        return travel
    }

    private func makeLayer(_ image: CGImage) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.cornerRadius = Self.cornerRadius
        layer.masksToBounds = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.isOpaque = false
        // Shadow is off: a shadow forces an offscreen pass per layer per frame.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }

    /// Model values jump to the target (implicit actions off); one spring per
    /// property carries the layer there from `start`. Animations stay after
    /// completion (`isRemovedOnCompletion = false`) so the layer never flashes
    /// back; a retarget replaces them under the same key. Initial velocity is
    /// not carried over on retarget: the new spring starts from rest at the
    /// presentation value.
    /// Returns the travel of the layer in points.
    private func animate(
        _ layer: CALayer, from start: LayerGeometry, to end: LayerGeometry, spring: OverlaySpring
    ) -> Double {
        layer.position = end.position
        layer.bounds = end.bounds
        if start.position != end.position {
            layer.add(
                springAnimation(
                    "position", from: NSValue(point: start.position), to: NSValue(point: end.position),
                    spring: spring, layer: layer
                ),
                forKey: "gio.position"
            )
        } else {
            layer.removeAnimation(forKey: "gio.position")
        }
        if start.bounds != end.bounds {
            layer.add(
                springAnimation(
                    "bounds", from: NSValue(rect: start.bounds), to: NSValue(rect: end.bounds),
                    spring: spring, layer: layer
                ),
                forKey: "gio.bounds"
            )
        } else {
            layer.removeAnimation(forKey: "gio.bounds")
        }
        let moved = flightTravel(
            from: CGRect(origin: CGPoint(x: start.position.x - start.bounds.width / 2, y: start.position.y - start.bounds.height / 2), size: start.bounds.size),
            to: CGRect(origin: CGPoint(x: end.position.x - end.bounds.width / 2, y: end.position.y - end.bounds.height / 2), size: end.bounds.size)
        )
        return moved
    }

    private func springAnimation(
        _ keyPath: String, from: NSValue, to: NSValue, spring: OverlaySpring, layer: CALayer
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = CGFloat(spring.mass)
        animation.stiffness = CGFloat(spring.stiffness)
        animation.damping = CGFloat(spring.damping)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = min(animation.settlingDuration, SpringParameters.maxDuration)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    private func removeAllLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.values {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        layers = [:]
        models = [:]
        CATransaction.commit()
    }

    private func teardown() {
        panel.orderOut(nil)
        panel.alphaValue = 1
        removeAllLayers()
        backdrop.contents = nil
    }
}

/// Owns the per-display overlays and the wallpaper backdrops. Main thread
/// only, except `wallpapers.hasImage`. The session host drives it through
/// closures on the main queue and never blocks on it.
@MainActor
public final class SnapshotOverlayController {
    public nonisolated let wallpapers = WallpaperCache()
    /// One overlay (panel) per display, kept between flights so a flight
    /// starts without creating a window; `active` are the ones showing.
    private var overlays: [String: SnapshotOverlay] = [:]
    private var active: Set<String> = []
    private var token = 0
    private var observers: [(center: NotificationCenter, object: NSObjectProtocol)] = []
    private var spring = SpringParameters.niri

    /// Called on main when every display's springs of flight `token` finished.
    public var onFlightFinished: ((Int) -> Void)?
    /// Called on main after the controller removed a flight on its own
    /// (watchdog, mouse down): the session must settle as if it had ended.
    public var onFlightAborted: ((Int, SnapshotAbortReason) -> Void)?
    /// SM-05: independent of the session queue, so a stalled queue or a lost
    /// completion callback can never leave the opaque overlay up.
    private var watchdog = FlightWatchdog()
    /// Landing time from Gio's own spring (not Core Animation completion).
    private var deadline = FlightDeadline()
    private var flightStartedAt: TimeInterval = 0
    private var flightTravel = 0.0

    public nonisolated init() {}

    public var isActive: Bool { !active.isEmpty }

    /// Refresh wallpapers now and whenever the screens, the Space or the
    /// wallpaper change.
    public func start() {
        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.desktop")),
        ]
        for (center, name) in names {
            let object = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWallpapers() }
            }
            observers.append((center, object))
        }
        refreshWallpapers()
    }

    /// Remove any overlay at once and stop observing (shutdown, restart).
    public func stop() {
        observers.forEach { $0.center.removeObserver($0.object) }
        observers = []
        for overlay in overlays.values {
            overlay.close()
        }
        overlays = [:]
        active = []
        deadline.abort()
    }

    /// Load the desktop image of every screen once (aspect-fill downsampled to
    /// the screen's pixel size) on a background queue.
    public func refreshWallpapers() {
        let screens = NSScreen.screens
        wallpapers.retain(only: screens.map(\.frame))
        let live = Set(screens.map { WallpaperCache.key($0.frame) })
        for (key, overlay) in overlays where !live.contains(key) && !active.contains(key) {
            overlay.close()
            overlays.removeValue(forKey: key)
        }
        for screen in screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
                wallpapers.store(nil, for: screen.frame)
                continue
            }
            let frame = screen.frame
            let maxPixels = Int(max(frame.width, frame.height) * screen.backingScaleFactor)
            let cache = wallpapers
            DispatchQueue.global(qos: .utility).async {
                cache.store(loadWallpaper(url: url, maxPixels: maxPixels), for: frame)
            }
        }
    }

    /// Start flight `token`. Returns false (nothing shown) when a display has
    /// no wallpaper yet: the caller falls back to the AX motion.
    @discardableResult
    public func begin(token: Int, spring: SpringParameters, flights: [SnapshotDisplayFlight]) -> Bool {
        self.spring = spring
        guard flights.allSatisfy({ wallpapers.hasImage(for: $0.displayFrame) }) else {
            return false
        }
        self.token = token
        endAll(fadeOut: false)
        armWatchdog()
        flightTravel = 0
        flightStartedAt = ProcessInfo.processInfo.systemUptime
        var travel = 0.0
        for flight in flights {
            let key = WallpaperCache.key(flight.displayFrame)
            let overlay = overlays[key] ?? SnapshotOverlay(displayFrame: flight.displayFrame, spring: spring)
            overlay.spring = spring
            overlays[key] = overlay
            active.insert(key)
            travel = max(
                travel, overlay.begin(backdropImage: wallpapers.image(for: flight.displayFrame), items: flight.items)
            )
        }
        flightTravel = travel
        scheduleDeadline(
            deadline.begin(now: ProcessInfo.processInfo.systemUptime, settle: flightSettleTime(spring: spring, travel: travel))
        )
        return true
    }

    /// Retarget layers and add new ones for the same flight `token`.
    public func retarget(token: Int, targets: [WindowID: CGRect], adding flights: [SnapshotDisplayFlight]) {
        self.token = token
        armWatchdog()
        var travel = 0.0
        for key in active.sorted() {
            guard let overlay = overlays[key] else {
                continue
            }
            let mine = targets.filter { overlay.ids.contains($0.key) }
            let added = flights.first { WallpaperCache.key($0.displayFrame) == key }?.items ?? []
            travel = max(travel, overlay.retarget(targets: mine, adding: added))
        }
        flightTravel = max(flightTravel, travel)
        scheduleDeadline(
            deadline.retarget(now: ProcessInfo.processInfo.systemUptime, settle: flightSettleTime(spring: spring, travel: travel))
        )
    }

    /// Remove every overlay (fade ~60 ms, or at once).
    public func end(fadeOut: Bool) {
        endAll(fadeOut: fadeOut)
    }

    /// A mouse button went down during a flight: remove the overlay at once
    /// so the click lands on the real window (already at its final frame).
    /// True when a flight was running.
    @discardableResult
    public func abortForMouseDown() -> Bool {
        guard !active.isEmpty else {
            return false
        }
        let aborted = token
        endAll(fadeOut: false)
        onFlightAborted?(aborted, .mouseDown)
        return true
    }

    private func armWatchdog() {
        let armed = watchdog.arm(at: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + FlightWatchdog.defaultLimit + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.watchdogFired(armed) }
        }
    }

    private func watchdogFired(_ armed: Int) {
        guard watchdog.isExpired(armed, now: ProcessInfo.processInfo.systemUptime), !active.isEmpty else {
            return
        }
        let aborted = token
        endAll(fadeOut: false)
        onFlightAborted?(aborted, .watchdog)
    }

    private func endAll(fadeOut: Bool) {
        watchdog.disarm()
        deadline.abort()
        for key in active {
            overlays[key]?.end(fadeOut: fadeOut)
        }
        active = []
    }

    /// One main-thread timer at the deadline; a retarget re-arms it and the
    /// stale timer sees a superseded token and does nothing.
    private func scheduleDeadline(_ armed: (token: Int, deadline: TimeInterval)) {
        let flightToken = token
        let delay = max(armed.deadline - ProcessInfo.processInfo.systemUptime, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.deadlineFired(armed.token, flightToken: flightToken) }
        }
    }

    private func deadlineFired(_ generationToken: Int, flightToken: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard flightToken == token, deadline.finish(generationToken, now: now) else {
            return
        }
        watchdog.disarm()
        let elapsed = now - flightStartedAt
        if flightTooShort(duration: elapsed, travel: flightTravel) {
            GioLog.record(.warn, "snapshot flight too short ms=\(Int((elapsed * 1000).rounded()))")
        }
        onFlightFinished?(flightToken)
    }
}

/// ImageIO downsample of the desktop image; nil when the URL is not a
/// single decodable image (a folder, a missing file).
private func loadWallpaper(url: URL, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
