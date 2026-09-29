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

    /// Called (main) when the springs of the latest begin/retarget finished.
    var onFinished: (() -> Void)?

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
    func begin(backdropImage: CGImage?, items: [SnapshotOverlayItem]) {
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
        fly(targets: [:], adding: items)
    }

    /// Retarget layers already flying (from their presentation values) and
    /// add layers for windows that were not part of the flight, in one
    /// transaction so completion means every spring finished.
    func retarget(targets: [WindowID: CGRect], adding items: [SnapshotOverlayItem]) {
        fly(targets: targets, adding: items)
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

    private func fly(targets: [WindowID: CGRect], adding items: [SnapshotOverlayItem]) {
        generation += 1
        let token = generation
        let mapping = overlaySpring(spring)
        var animated = 0
        CATransaction.begin()
        for (id, frame) in targets.sorted(by: { $0.key < $1.key }) {
            guard let layer = layers[id], let model = models[id] else {
                continue
            }
            let next = overlayLayerGeometry(frame: frame, in: displayFrame, flipped: root.isFlipped)
            let start = retargetStart(
                presentation: (layer.presentation()).map { LayerGeometry(position: $0.position, bounds: $0.bounds) },
                model: model
            )
            animated += animate(layer, from: start, to: next, spring: mapping)
            models[id] = next
        }
        for item in items {
            let layer = makeLayer(item.image)
            let start = overlayLayerGeometry(frame: item.from, in: displayFrame, flipped: root.isFlipped)
            let end = overlayLayerGeometry(frame: item.to, in: displayFrame, flipped: root.isFlipped)
            layers[item.id]?.removeFromSuperlayer()
            root.layer?.addSublayer(layer)
            layers[item.id] = layer
            animated += animate(layer, from: start, to: end, spring: mapping)
            models[item.id] = end
        }
        let finish: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else {
                    return
                }
                self.onFinished?()
            }
        }
        if animated > 0 {
            CATransaction.setCompletionBlock(finish)
        }
        CATransaction.commit()
        if animated == 0 {
            // Nothing moves (targets equal the starts): finished right away.
            DispatchQueue.main.async(execute: finish)
        }
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
    @discardableResult
    private func animate(
        _ layer: CALayer, from start: LayerGeometry, to end: LayerGeometry, spring: OverlaySpring
    ) -> Int {
        var count = 0
        layer.position = end.position
        layer.bounds = end.bounds
        if start.position != end.position {
            layer.add(
                springAnimation(
                    "position", from: NSValue(point: start.position), to: NSValue(point: end.position), spring: spring
                ),
                forKey: "gio.position"
            )
            count += 1
        } else {
            layer.removeAnimation(forKey: "gio.position")
        }
        if start.bounds != end.bounds {
            layer.add(
                springAnimation(
                    "bounds", from: NSValue(rect: start.bounds), to: NSValue(rect: end.bounds), spring: spring
                ),
                forKey: "gio.bounds"
            )
            count += 1
        } else {
            layer.removeAnimation(forKey: "gio.bounds")
        }
        return count
    }

    private func springAnimation(
        _ keyPath: String, from: NSValue, to: NSValue, spring: OverlaySpring
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = CGFloat(spring.mass)
        animation.stiffness = CGFloat(spring.stiffness)
        animation.damping = CGFloat(spring.damping)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = min(animation.settlingDuration, SpringParameters.maxDuration)
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
    private var pending: Set<String> = []
    private var token = 0
    private var observers: [(center: NotificationCenter, object: NSObjectProtocol)] = []
    private var spring = SpringParameters.niri

    /// Called on main when every display's springs of flight `token` finished.
    public var onFlightFinished: ((Int) -> Void)?

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
        pending = []
    }

    public func setSpring(_ spring: SpringParameters) {
        self.spring = spring
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
    public func begin(token: Int, flights: [SnapshotDisplayFlight]) -> Bool {
        guard flights.allSatisfy({ wallpapers.hasImage(for: $0.displayFrame) }) else {
            return false
        }
        self.token = token
        endAll(fadeOut: false)
        pending = []
        for flight in flights {
            let key = WallpaperCache.key(flight.displayFrame)
            let overlay = overlays[key] ?? SnapshotOverlay(displayFrame: flight.displayFrame, spring: spring)
            overlay.spring = spring
            overlays[key] = overlay
            active.insert(key)
            pending.insert(key)
            overlay.onFinished = { [weak self] in self?.finished(key, token: token) }
            overlay.begin(backdropImage: wallpapers.image(for: flight.displayFrame), items: flight.items)
        }
        return true
    }

    /// Retarget layers and add new ones for the same flight `token`.
    public func retarget(token: Int, targets: [WindowID: CGRect], adding flights: [SnapshotDisplayFlight]) {
        self.token = token
        pending = active
        for key in active.sorted() {
            guard let overlay = overlays[key] else {
                continue
            }
            let mine = targets.filter { overlay.ids.contains($0.key) }
            let added = flights.first { WallpaperCache.key($0.displayFrame) == key }?.items ?? []
            overlay.onFinished = { [weak self] in self?.finished(key, token: token) }
            overlay.retarget(targets: mine, adding: added)
        }
    }

    /// Remove every overlay (fade ~60 ms, or at once).
    public func end(fadeOut: Bool) {
        endAll(fadeOut: fadeOut)
    }

    private func endAll(fadeOut: Bool) {
        for key in active {
            overlays[key]?.onFinished = nil
            overlays[key]?.end(fadeOut: fadeOut)
        }
        active = []
        pending = []
    }

    private func finished(_ key: String, token: Int) {
        guard token == self.token else {
            return
        }
        pending.remove(key)
        if pending.isEmpty {
            onFlightFinished?(token)
        }
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
