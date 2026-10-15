import AppKit
import GioCore
import QuartzCore

// SM-03/SM-08: GPU snapshot overlay. Main thread only (AppKit + Core
// Animation). Compile-checked; every decision it takes (coordinates, spring
// tracks and keyframes, velocity carry, shadow/ring/dim geometry, watchdog,
// deadline) is pure and tested in GioCore (`OverlayGeometry`,
// `OverlayDecorations`). During a flight Gio does no per-frame work: the
// render server plays keyframe tracks sampled from Gio's own spring.
//
// Window levels (higher is in front): app windows `.normal` = 0, this overlay
// `.normal + 1` = 1, the focus ring `.floating` = 3, Dock 20, menus 24 and
// above. The overlay is therefore in front of ordinary windows but behind
// the Dock and the menu bar.
//
// SM-18: the panel covers only the display's usable frame (menu bar and Dock
// excluded, `OverlayArea`). The live menu bar and Dock are translucent and
// draw above it; a display-sized panel showed the captured (stale) menu bar
// and Dock through them. Layers, holes and the mask are local to the usable
// frame; the backdrop layer crops the display capture with `contentsRect`.
//
// SM-14: the panel is not opaque for the WindowServer (`isOpaque = false`,
// clear background, no shadow) although its layers draw an opaque picture
// (backdrop on a black fill). An opaque display-sized panel
// marks every window under it occluded, and apps that stop painting occluded
// windows (Chromium/Electron) showed blank areas when it came down.
//
// SM-16: windows that fly without an image show through holes in that
// picture: the backdrop layer (fill included) is masked by an even-odd
// `CAShapeLayer` (display minus the holes, `overlayBackdropMask`), set at
// begin and on retarget only. The root layer is clear, so a hole is
// transparent down to the real window under the panel.
//
// SM-30: a resized window's fresh image of its landing size, captured
// mid-flight, fades in on top of its layer (`freshen`, 100 ms, timed). At
// the hand-off of a flight with resized windows the backdrop and every other
// layer go at once and the resized layers fade out over their real windows
// (`fadeOut`, 120 ms); a mouse down, a new flight or a stop ends the fade.

/// One window image to fly. Frames are Cocoa global coordinates. SM-27:
/// `image` is drawn at its own size, never scaled; `target` is the image of
/// the `to` size it shows instead from the first frame (SM-32; the same image
/// on a move, nil when none is cached).
public struct SnapshotOverlayItem: @unchecked Sendable {
    public let id: WindowID
    public let image: SnapshotFace<CGImage>
    public let target: SnapshotFace<CGImage>?
    public let from: CGRect
    public let to: CGRect

    public init(
        id: WindowID, image: SnapshotFace<CGImage>, target: SnapshotFace<CGImage>?, from: CGRect, to: CGRect
    ) {
        self.id = id
        self.image = image
        self.target = target
        self.from = from
        self.to = to
    }
}

/// The items of one display's overlay over the display's captured backdrop
/// (everything on it except the managed windows, SM-09). SM-18: the panel
/// covers `usableFrame` only (menu bar and Dock excluded).
public struct SnapshotDisplayFlight: @unchecked Sendable {
    public let displayFrame: CGRect
    public let usableFrame: CGRect
    public let backdrop: CGImage
    public let items: [SnapshotOverlayItem]

    public init(displayFrame: CGRect, usableFrame: CGRect, backdrop: CGImage, items: [SnapshotOverlayItem]) {
        self.displayFrame = displayFrame
        self.usableFrame = usableFrame
        self.backdrop = backdrop
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

private func displayKey(_ frame: CGRect) -> String {
    "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
}

@MainActor private let noActions: [String: CAAction] = [
    "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "shadowPath": NSNull(),
    "hidden": NSNull(), "opacity": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(),
    "backgroundColor": NSNull(), "sublayers": NSNull(),
]

/// SM-27: one image a window layer can show, inside its clip: a group
/// (whose opacity says whether it shows) holding the fill and, on top,
/// the image at its own size, both hanging from the clip's top-left corner.
@MainActor
private final class FaceLayers {
    let source: SnapshotFace<CGImage>
    let group = CALayer()
    let fill = CALayer()
    let image = CALayer()

    init(_ source: SnapshotFace<CGImage>) {
        self.source = source
        for layer in [group, fill, image] {
            layer.actions = noActions
        }
        group.frame = .zero
        if let color = source.fill {
            fill.backgroundColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor
        }
        image.contents = source.image
        // The layer is the image's own size (points), so `.resize` scales
        // uniformly (an SM-22 half-resolution image doubles), never stretches.
        image.contentsGravity = .resize
        image.magnificationFilter = .linear
        image.minificationFilter = .linear
        group.addSublayer(fill)
        group.addSublayer(image)
    }

    func layout(reach: CGSize) {
        let frames = overlayFaceFrames(image: source.size, reach: reach)
        image.frame = frames.image
        fill.frame = frames.fill
    }
}

/// The layers of one window, bottom to top: the shadow it casts into the
/// gaps (precomputed `shadowPath`, no offscreen pass), the clipped image,
/// the dim fill and the ring. All four follow the same track, so they move
/// as one. SM-27: the clip has the window's frame and corner radius; a pure
/// move draws its image as the clip's own contents (as before), anything
/// else draws faces inside it (`OverlayFaces`): never a stretched image.
@MainActor
private final class WindowLayers {
    let shadow = CALayer()
    let clip = CALayer()
    let dim = CALayer()
    let ring = CALayer()
    /// Where the window flies from and to; `startedAt` (CA media time) is
    /// nil while primed and not flying yet.
    var track: FlightTrack
    var startedAt: CFTimeInterval?
    private var ringWidth: CGFloat = 0
    /// SM-27: the images the layer can show, bottom to top, which one shows
    /// (SM-32: one at a time), and their layers once the clip draws faces
    /// (empty while it draws the first image directly).
    private var sources: [SnapshotFace<CGImage>]
    private var shown = OverlayFaces()
    private var faces: [FaceLayers] = []
    /// The largest frame of the current track (keyframes included): how far
    /// the fills reach.
    private var reach: CGSize = .zero

    var all: [CALayer] { [shadow, clip, dim, ring] }

    init(image source: SnapshotFace<CGImage>, scale: CGFloat, track: FlightTrack) {
        self.track = track
        sources = [source]
        for layer in all {
            layer.actions = noActions
            layer.contentsScale = scale
        }
        shadow.zPosition = 0
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = overlayWindowShadow.opacity
        shadow.shadowRadius = overlayWindowShadow.radius
        shadow.shadowOffset = overlayWindowShadow.offset
        clip.zPosition = 1
        clip.contents = source.image
        // A pure move: the image fills the frame it matches (within 2 pt).
        clip.contentsGravity = .resize
        clip.cornerRadius = overlayWindowCornerRadius
        clip.masksToBounds = true
        clip.magnificationFilter = .linear
        clip.minificationFilter = .linear
        dim.zPosition = 2
        dim.backgroundColor = NSColor.black.cgColor
        dim.cornerRadius = overlayWindowCornerRadius
        dim.isHidden = true
        ring.zPosition = 3
        ring.isHidden = true
        apply(track.start)
    }

    /// SM-32: from now on the layer shows `target` (the image of the end
    /// size: a face it has, or a new one on top) alone, or without one its
    /// face closest in size. No dissolve: two layouts never mix.
    func show(_ target: SnapshotFace<CGImage>?) {
        let index: Int
        if let target {
            index = sources.firstIndex { $0.image === target.image } ?? sources.count
            if index == sources.count {
                sources.append(target)
            }
        } else {
            index = overlayClosestFace(sources.map(\.size), to: track.end.bounds.size)
        }
        shown = shown.showing(index)
        if faces.isEmpty, overlayDrawsDirect(
            image: sources[0].size, faces: sources.count, start: track.start.bounds.size, end: track.end.bounds.size
        ) {
            return
        }
        buildFaces()
        for (face, opacity) in zip(faces, shown.opacities) {
            face.group.removeAnimation(forKey: "gio.opacity")
            face.group.opacity = Float(opacity)
        }
        layoutFaces(reach: overlayReach([reach, track.start.bounds.size, track.end.bounds.size]))
    }

    /// SM-30: a fresh image of the landing size, captured mid-flight: a new
    /// face on top fading in over `overlayFreshFadeDuration` from `now`
    /// (eased, timed: the resize is nearly done); the faces under it keep
    /// their opacity.
    func freshen(_ source: SnapshotFace<CGImage>, now: CFTimeInterval) {
        sources.append(source)
        shown = shown.freshened()
        buildFaces()
        let opacities = shown.opacities
        for (index, face) in faces.enumerated().dropLast() {
            face.group.removeAnimation(forKey: "gio.opacity")
            face.group.opacity = Float(opacities[index])
        }
        layoutFaces(reach: overlayReach([reach, track.start.bounds.size, track.end.bounds.size]))
        let top = faces[faces.count - 1].group
        top.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = overlayFreshFadeDuration
        animation.beginTime = top.convertTime(now, from: nil)
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        top.add(animation, forKey: "gio.opacity")
    }

    /// SM-30: the soft hand-off: shadow, image and dim fade out over the
    /// real window from `now` (eased); the live ring above replaces this one.
    func fadeOut(duration: TimeInterval, now: CFTimeInterval) {
        ring.isHidden = true
        for layer in [shadow, clip, dim] {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = layer.opacity
            animation.toValue = 0
            animation.duration = duration
            animation.beginTime = layer.convertTime(now, from: nil)
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.opacity = 0
            layer.add(animation, forKey: "gio.fade")
        }
    }

    /// The clip draws faces: its own contents go, a layer per source not yet
    /// drawn joins on top.
    private func buildFaces() {
        clip.contents = nil
        for source in sources.dropFirst(faces.count) {
            let face = FaceLayers(source)
            face.group.zPosition = CGFloat(faces.count)
            faces.append(face)
            clip.addSublayer(face.group)
        }
    }

    private func layoutFaces(reach: CGSize) {
        self.reach = reach
        for face in faces {
            face.layout(reach: reach)
        }
    }

    /// Model values (no implicit animation) for every layer.
    func apply(_ geometry: LayerGeometry) {
        for layer in [shadow, clip, dim] {
            layer.position = geometry.position
        }
        shadow.bounds = geometry.bounds
        dim.bounds = geometry.bounds
        clip.bounds = overlayClipBounds(geometry.bounds.size)
        shadow.shadowPath = overlayShadowPath(bounds: geometry.bounds, cornerRadius: overlayWindowCornerRadius)
        let outset = overlayRingGeometry(window: geometry, width: ringWidth)
        ring.position = outset.position
        ring.bounds = outset.bounds
    }

    func decorate(ring spec: OverlayRing?, dimAlpha: Float?) {
        if let spec {
            ringWidth = spec.width
            ring.borderWidth = spec.width
            ring.cornerRadius = overlayRingCornerRadius(width: spec.width)
            ring.borderColor = NSColor(
                srgbRed: spec.color.red, green: spec.color.green, blue: spec.color.blue, alpha: 1
            ).cgColor
            ring.isHidden = false
        } else {
            ringWidth = 0
            ring.isHidden = true
        }
        if let dimAlpha {
            dim.opacity = dimAlpha
            dim.isHidden = false
        } else {
            dim.isHidden = true
        }
    }

    /// Model values jump to the end; keyframe tracks (kept after completion,
    /// `fillMode .both`) carry every layer there. A retarget replaces them
    /// under the same keys.
    func animate(_ keyframes: FlightKeyframes, beginTime: CFTimeInterval) {
        apply(track.end)
        let times = keyframes.times.map { NSNumber(value: $0) }
        let positions = keyframes.geometries.map { NSValue(point: $0.position) }
        let bounds = keyframes.geometries.map { NSValue(rect: $0.bounds) }
        let moves = track.start.position != track.end.position
        let resizes = track.start.bounds != track.end.bounds
        for layer in [shadow, clip, dim] {
            Self.setTrack(layer, "position", values: moves ? positions : nil, times: times, keyframes: keyframes, beginTime: beginTime)
        }
        for layer in [shadow, dim] {
            Self.setTrack(layer, "bounds", values: resizes ? bounds : nil, times: times, keyframes: keyframes, beginTime: beginTime)
        }
        Self.setTrack(
            clip, "bounds",
            values: resizes ? keyframes.geometries.map { NSValue(rect: overlayClipBounds($0.bounds.size)) } : nil,
            times: times, keyframes: keyframes, beginTime: beginTime
        )
        Self.setTrack(
            shadow, "shadowPath",
            values: resizes
                ? keyframes.geometries.map { overlayShadowPath(bounds: $0.bounds, cornerRadius: overlayWindowCornerRadius) }
                : nil,
            times: times, keyframes: keyframes, beginTime: beginTime, discrete: true
        )
        let outsets = keyframes.geometries.map { overlayRingGeometry(window: $0, width: ringWidth) }
        Self.setTrack(ring, "position", values: moves ? positions : nil, times: times, keyframes: keyframes, beginTime: beginTime)
        Self.setTrack(
            ring, "bounds", values: resizes ? outsets.map { NSValue(rect: $0.bounds) } : nil,
            times: times, keyframes: keyframes, beginTime: beginTime
        )
        guard !faces.isEmpty else {
            return
        }
        // SM-27: the fills reach the largest frame of this track (a spring
        // overshoot included). SM-32: the shown face does not change along it.
        layoutFaces(reach: overlayReach(keyframes.geometries.map(\.bounds.size)))
    }

    func removeAnimations() {
        all.forEach { $0.removeAllAnimations() }
        faces.forEach { $0.group.removeAllAnimations() }
    }

    func removeFromSuperlayer() {
        all.forEach { $0.removeFromSuperlayer() }
    }

    /// One keyframe track per property, or none when the property does not
    /// change (the model value already holds). `discrete` for `CGPath`
    /// values: one path per sample at the display rate, no interpolation.
    private static func setTrack(
        _ layer: CALayer, _ keyPath: String, values: [Any]?, times: [NSNumber], keyframes: FlightKeyframes,
        beginTime: CFTimeInterval, discrete: Bool = false
    ) {
        let key = "gio.\(keyPath)"
        guard let values else {
            layer.removeAnimation(forKey: key)
            return
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.calculationMode = discrete ? .discrete : .linear
        animation.duration = keyframes.duration
        animation.beginTime = layer.convertTime(beginTime, from: nil)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }
}

/// One display's overlay: a panel that draws an opaque picture (the captured
/// backdrop and the layers of every visible managed window of that display)
/// without being opaque to the WindowServer (SM-14: no occlusion).
@MainActor
final class SnapshotOverlay {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)

    let displayFrame: CGRect
    /// SM-18: display and panel frame of the current flight; layers are
    /// local to `area.panelFrame`. Set at every begin (the Dock may move
    /// between flights; a move during one aborts it).
    private var area: OverlayArea
    private let panel: OverlayPanel
    private let root: OverlayRootView
    private let backdrop = CALayer()
    private let backdropMask = CAShapeLayer()
    private var windows: [WindowID: WindowLayers] = [:]
    var spring: SpringParameters

    var ids: Set<WindowID> { Set(windows.keys) }

    init(displayFrame: CGRect, spring: SpringParameters) {
        self.displayFrame = displayFrame
        area = OverlayArea(display: displayFrame, usable: displayFrame)
        self.spring = spring
        panel = OverlayPanel(
            contentRect: displayFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        root = OverlayRootView(frame: CGRect(origin: .zero, size: displayFrame.size))
        // SM-14: not opaque, so the windows underneath are not occluded; the
        // root layer's fill and the backdrop make the picture opaque.
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
        // SM-16: the black fill is the backdrop's own, so a hole in the
        // backdrop is clear down to the real window.
        root.layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.zPosition = -1
        backdrop.frame = root.bounds
        backdrop.backgroundColor = NSColor.black.cgColor
        // The capture is display-sized at the backing scale; `contentsRect`
        // crops it to the panel (SM-18), drawn 1:1.
        backdrop.contentsGravity = .resize
        backdrop.masksToBounds = true
        backdrop.actions = [
            "contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull(), "mask": NSNull(),
        ]
        backdropMask.fillRule = .evenOdd
        backdropMask.fillColor = NSColor.black.cgColor
        backdropMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.layer?.addSublayer(backdrop)
        panel.contentView = root
    }

    private var scale: CGFloat {
        panel.screen?.backingScaleFactor ?? panel.backingScaleFactor
    }

    /// Keyframes per second: the display's refresh rate (at least 60).
    private var sampleRate: Double {
        Double(max(panel.screen?.maximumFramesPerSecond ?? 60, 60))
    }

    /// SM-12: the view whose screen the frame link follows, and that
    /// screen's refresh rate (the expected frames per second).
    var frameView: NSView { root }
    var refreshRate: Double { sampleRate }

    // MARK: API

    /// Prime: backdrop and every window's layers at their start frames, the
    /// panel on screen and its first frame committed to the render server.
    /// False when the panel did not make it to the screen.
    func begin(
        usable: CGRect, backdrop image: CGImage, items: [SnapshotOverlayItem], holes: [CGRect],
        decorations: OverlayDecorations
    ) -> Bool {
        area = OverlayArea(display: displayFrame, usable: usable)
        panel.setFrame(area.panelFrame, display: false)
        root.frame = CGRect(origin: .zero, size: area.panelFrame.size)
        removeAllLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = root.bounds
        backdrop.contentsScale = scale
        backdrop.isHidden = false
        backdrop.contents = image
        // The capture's own pixels per point (the backing scale when 1:1).
        backdrop.contentsRect = area.backdropContentsRect(
            scale: CGFloat(image.width) / max(displayFrame.width, 1), flipped: backdrop.contentsAreFlipped()
        )
        cut(holes)
        for item in items {
            add(item)
        }
        applyDecorations(decorations)
        CATransaction.commit()
        panel.orderFrontRegardless()
        root.displayIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        return panel.isVisible
    }

    /// The real windows are written: every primed layer starts its track
    /// now. Returns the longest settle time (seconds) for the deadline.
    func fly(now: CFTimeInterval) -> TimeInterval {
        var settle = 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layers in windows.values where layers.startedAt == nil {
            settle = max(settle, start(layers, at: now))
        }
        CATransaction.commit()
        return settle
    }

    /// Retarget flying layers (from where they are now, carrying their
    /// velocity) and add layers for windows that joined. Layers still primed
    /// only change their target. SM-32: each shows the image of its new size
    /// at once (`images`; without one, its closest image). Returns the longest
    /// settle time of the tracks started here (0 while primed).
    func retarget(
        targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>], adding items: [SnapshotOverlayItem],
        holes: [CGRect], decorations: OverlayDecorations, now: CFTimeInterval
    ) -> TimeInterval {
        var settle = 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cut(holes)
        // Joining windows first, then the ring/dim (the ring width shapes the
        // tracks), then the tracks.
        let added = items.map { add($0) }
        applyDecorations(decorations)
        for (id, frame) in targets.sorted(by: { $0.key < $1.key }) {
            guard let layers = windows[id] else {
                continue
            }
            let end = overlayLayerGeometry(frame: frame, in: area.panelFrame, flipped: root.isFlipped)
            if let startedAt = layers.startedAt {
                layers.track = layers.track.retargeted(to: end, at: now - startedAt, spring: spring)
                layers.show(images[id])
                settle = max(settle, start(layers, at: now))
            } else {
                layers.track.end = end
                layers.show(images[id])
            }
        }
        if windows.values.contains(where: { $0.startedAt != nil }) {
            for layers in added {
                settle = max(settle, start(layers, at: now))
            }
        }
        CATransaction.commit()
        return settle
    }

    /// SM-30: fresh images of resized layers' landing sizes: each layer
    /// fades its image in on top.
    func freshen(_ faces: [WindowID: SnapshotFace<CGImage>], now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, face) in faces.sorted(by: { $0.key < $1.key }) {
            windows[id]?.freshen(face, now: now)
        }
        CATransaction.commit()
    }

    /// SM-30: the soft hand-off: the backdrop and every layer but those of
    /// `ids` go at once (the real desktop is under them); those fade out
    /// over their real windows in `duration`. False when none is left (the
    /// caller ends the overlay).
    func fadeOut(keeping ids: Set<WindowID>, duration: TimeInterval, now: CFTimeInterval) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.isHidden = true
        backdrop.contents = nil
        backdrop.mask = nil
        for (id, layers) in windows where !ids.contains(id) {
            layers.removeAnimations()
            layers.removeFromSuperlayer()
            windows.removeValue(forKey: id)
        }
        for layers in windows.values {
            layers.fadeOut(duration: duration, now: now)
        }
        CATransaction.commit()
        return !windows.isEmpty
    }

    /// Remove the overlay at once: with the backdrop, shadows, ring and dim
    /// matching the real desktop, the swap needs no fade.
    func end() {
        panel.orderOut(nil)
        removeAllLayers()
        backdrop.contents = nil
        backdrop.mask = nil
    }

    func close() {
        end()
        panel.close()
    }

    // MARK: Layers

    /// SM-16: the backdrop shows everything but `holes` (Cocoa global
    /// frames; the ones off this display are ignored). No holes: no mask.
    private func cut(_ holes: [CGRect]) {
        guard let path = overlayBackdropMask(holes: holes, in: area.panelFrame, flipped: root.isFlipped) else {
            backdrop.mask = nil
            return
        }
        backdropMask.frame = backdrop.bounds
        backdropMask.path = path
        backdrop.mask = backdropMask
    }

    @discardableResult
    private func add(_ item: SnapshotOverlayItem) -> WindowLayers {
        windows[item.id]?.removeFromSuperlayer()
        let layers = WindowLayers(
            image: item.image, scale: scale,
            track: FlightTrack(
                start: overlayLayerGeometry(frame: item.from, in: area.panelFrame, flipped: root.isFlipped),
                end: overlayLayerGeometry(frame: item.to, in: area.panelFrame, flipped: root.isFlipped)
            )
        )
        layers.show(item.target)
        layers.all.forEach { root.layer?.addSublayer($0) }
        windows[item.id] = layers
        return layers
    }

    private func start(_ layers: WindowLayers, at now: CFTimeInterval) -> TimeInterval {
        let keyframes = flightKeyframes(track: layers.track, spring: spring, rate: sampleRate)
        layers.startedAt = now
        layers.animate(keyframes, beginTime: now)
        return keyframes.duration
    }

    private func applyDecorations(_ decorations: OverlayDecorations) {
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dimAlpha = decorations.dim.map { Float(focusDimAlpha(strength: $0.strength, darkAppearance: dark)) }
        for (id, layers) in windows {
            layers.decorate(
                ring: decorations.ring?.id == id ? decorations.ring : nil,
                dimAlpha: decorations.dim?.ids.contains(id) == true ? dimAlpha : nil
            )
            if layers.startedAt == nil {
                layers.apply(layers.track.start)
            } else {
                layers.apply(layers.track.end)
            }
        }
    }

    private func removeAllLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layers in windows.values {
            layers.removeAnimations()
            layers.removeFromSuperlayer()
        }
        windows = [:]
        CATransaction.commit()
    }
}

/// Owns the per-display overlays. Main thread only. The session host drives
/// it through closures on the main queue and never blocks on it.
@MainActor
public final class SnapshotOverlayController {
    /// One overlay (panel) per display, kept between flights so a flight
    /// starts without creating a window; `active` are the ones showing.
    private var overlays: [String: SnapshotOverlay] = [:]
    private var active: Set<String> = []
    /// SM-30: overlays whose resized layers fade out after a hand-off (the
    /// flight is over, `active` is empty); `fadeGeneration` tells their
    /// removal timer from a newer fade's. A new flight, a mouse down or a
    /// stop removes them at once.
    private var fading: Set<String> = []
    private var fadeGeneration = 0
    private var token = 0
    private var flying = false
    private var observers: [NSObjectProtocol] = []
    private var spring = SpringParameters.niri

    /// Called on main when every display's tracks of flight `token` landed,
    /// with the frames the display presented during the flight (SM-12; nil
    /// without a display link).
    public var onFlightFinished: ((Int, FlightFrameStats?) -> Void)?
    /// Called on main after the controller removed a flight on its own
    /// (watchdog, mouse down): the session must settle as if it had ended.
    public var onFlightAborted: ((Int, SnapshotAbortReason) -> Void)?
    /// SM-19: called on main with flight `token` and its landing time
    /// (`systemUptime`) whenever the deadline is armed (fly, retarget), so
    /// the session checks paint before the layers land.
    public var onDeadlineArmed: ((Int, TimeInterval) -> Void)?
    /// SM-05: independent of the session queue, so a stalled queue, a lost
    /// prime report or a lost completion can never leave the overlay up.
    /// SM-14: re-armed at the deadline for the hand-off hold
    /// (`SnapshotHandoff.watchdogLimit`: the hold cap plus a margin).
    private var watchdog = FlightWatchdog()
    /// Landing time from Gio's own spring (not Core Animation completion).
    private var deadline = FlightDeadline()
    private var flightStartedAt: TimeInterval = 0
    private var flightTravel = 0.0
    /// SM-12: display link while the layers fly; none at rest.
    private let frameLink = FlightFrameLink()

    public nonisolated init() {}

    public var isActive: Bool { !active.isEmpty }

    /// Drop the panels of displays that went away (never a showing one).
    public func start() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneOverlays() }
        }
        observers.append(observer)
    }

    /// Remove any overlay at once and stop observing (shutdown, restart).
    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for overlay in overlays.values {
            overlay.close()
        }
        overlays = [:]
        active = []
        fading = []
        flying = false
        deadline.abort()
        frameLink.cancel()
    }

    private func pruneOverlays() {
        let live = Set(NSScreen.screens.map { displayKey($0.frame) })
        for (key, overlay) in overlays where !live.contains(key) && !active.contains(key) && !fading.contains(key) {
            overlay.close()
            overlays.removeValue(forKey: key)
        }
    }

    /// Prime flight `token`: every display's overlay on screen with the
    /// layers at their start frames. False (nothing left on screen) when a
    /// panel could not be shown: the session falls back to AX before any
    /// real write.
    @discardableResult
    public func begin(
        token: Int, spring: SpringParameters, flights: [SnapshotDisplayFlight], holes: [CGRect],
        decorations: OverlayDecorations
    ) -> Bool {
        self.spring = spring
        self.token = token
        endAll()
        flightTravel = flights.flatMap(\.items).map { GioCore.flightTravel(from: $0.from, to: $0.to) }.max() ?? 0
        for flight in flights {
            let key = displayKey(flight.displayFrame)
            let overlay = overlays[key] ?? SnapshotOverlay(displayFrame: flight.displayFrame, spring: spring)
            overlay.spring = spring
            overlays[key] = overlay
            active.insert(key)
            guard overlay.begin(
                usable: flight.usableFrame, backdrop: flight.backdrop, items: flight.items, holes: holes, decorations: decorations
            ) else {
                endAll()
                return false
            }
        }
        armWatchdog()
        return true
    }

    /// The real windows of flight `token` are written: the layers fly.
    public func fly(token: Int) {
        guard token == self.token, !active.isEmpty, !flying else {
            return
        }
        flying = true
        armWatchdog()
        let now = CACurrentMediaTime()
        var settle = 0.0
        for key in active.sorted() {
            settle = max(settle, overlays[key]?.fly(now: now) ?? 0)
        }
        flightStartedAt = ProcessInfo.processInfo.systemUptime
        if let key = active.sorted().first, let overlay = overlays[key] {
            frameLink.start(on: overlay.frameView, refreshRate: overlay.refreshRate, at: now)
        }
        scheduleDeadline(deadline.begin(now: ProcessInfo.processInfo.systemUptime, settle: settle))
    }

    /// Retarget layers and add new ones for the same flight `token`;
    /// `holes` replaces every backdrop's holes (SM-16); `images` are the
    /// images of the retargeted layers' new sizes (SM-27).
    public func retarget(
        token: Int, targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>],
        adding flights: [SnapshotDisplayFlight], holes: [CGRect], decorations: OverlayDecorations
    ) {
        self.token = token
        armWatchdog()
        let now = CACurrentMediaTime()
        var settle = 0.0
        for key in active.sorted() {
            guard let overlay = overlays[key] else {
                continue
            }
            let mine = targets.filter { overlay.ids.contains($0.key) }
            let added = flights.first { displayKey($0.displayFrame) == key }?.items ?? []
            settle = max(
                settle,
                overlay.retarget(
                    targets: mine, images: images, adding: added, holes: holes, decorations: decorations, now: now
                )
            )
        }
        flightTravel = max(
            flightTravel, flights.flatMap(\.items).map { GioCore.flightTravel(from: $0.from, to: $0.to) }.max() ?? 0
        )
        if flying {
            if let key = active.sorted().first, let overlay = overlays[key] {
                frameLink.retargeted(on: overlay.frameView, refreshRate: overlay.refreshRate, at: now)
            }
            scheduleDeadline(deadline.retarget(now: ProcessInfo.processInfo.systemUptime, settle: settle))
        }
    }

    /// Remove every overlay at once.
    public func end() {
        endAll()
    }

    /// SM-30: fresh images of resized layers' landing sizes for flight
    /// `token`: each layer fades to its image on top.
    public func freshen(token: Int, faces: [WindowID: SnapshotFace<CGImage>]) {
        guard token == self.token, !active.isEmpty else {
            return
        }
        let now = CACurrentMediaTime()
        for key in active.sorted() {
            guard let overlay = overlays[key] else {
                continue
            }
            let mine = faces.filter { overlay.ids.contains($0.key) }
            if !mine.isEmpty {
                overlay.freshen(mine, now: now)
            }
        }
    }

    /// SM-30: the soft hand-off. The flight is over (watchdog, deadline and
    /// frame link stop); the backdrops and every layer but those of `ids` go
    /// at once, those fade out over their real windows in `duration`, then
    /// the overlays come down.
    public func fadeOut(windows ids: Set<WindowID>, duration: TimeInterval) {
        guard !active.isEmpty else {
            return
        }
        let keys = active
        watchdog.disarm()
        deadline.abort()
        frameLink.cancel()
        active = []
        flying = false
        let now = CACurrentMediaTime()
        for key in keys.sorted() {
            guard let overlay = overlays[key] else {
                continue
            }
            if overlay.fadeOut(keeping: ids, duration: duration, now: now) {
                fading.insert(key)
            } else {
                overlay.end()
            }
        }
        guard !fading.isEmpty else {
            return
        }
        fadeGeneration += 1
        let generation = fadeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.fadeGeneration else {
                    return
                }
                self.endFading()
            }
        }
    }

    /// A mouse button went down during a flight: remove the overlay at once
    /// so the click lands on the real window. True when a flight was running.
    @discardableResult
    public func abortForMouseDown() -> Bool {
        guard !active.isEmpty else {
            // SM-30: a click during the soft hand-off lands on the real
            // window it already is; the fading picture goes at once.
            endFading()
            return false
        }
        let aborted = token
        endAll()
        onFlightAborted?(aborted, .mouseDown)
        return true
    }

    private func armWatchdog(limit: TimeInterval = FlightWatchdog.defaultLimit) {
        let armed = watchdog.arm(at: ProcessInfo.processInfo.systemUptime, limit: limit)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.watchdogFired(armed) }
        }
    }

    private func watchdogFired(_ armed: Int) {
        guard watchdog.isExpired(armed, now: ProcessInfo.processInfo.systemUptime), !active.isEmpty else {
            return
        }
        let aborted = token
        endAll()
        onFlightAborted?(aborted, .watchdog)
    }

    private func endAll() {
        watchdog.disarm()
        deadline.abort()
        frameLink.cancel()
        for key in active {
            overlays[key]?.end()
        }
        active = []
        flying = false
        endFading()
    }

    private func endFading() {
        for key in fading {
            overlays[key]?.end()
        }
        fading = []
    }

    /// One main-thread timer at the deadline; a retarget re-arms it and the
    /// stale timer sees a superseded token and does nothing.
    private func scheduleDeadline(_ armed: (token: Int, deadline: TimeInterval)) {
        let flightToken = token
        let delay = max(armed.deadline - ProcessInfo.processInfo.systemUptime, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.deadlineFired(armed.token, flightToken: flightToken) }
        }
        onDeadlineArmed?(flightToken, armed.deadline)
    }

    private func deadlineFired(_ generationToken: Int, flightToken: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard flightToken == token, deadline.finish(generationToken, now: now) else {
            return
        }
        // SM-14: the session may hold the overlay (layers at rest) until the
        // windows painted; the watchdog bounds that hold.
        armWatchdog(limit: SnapshotHandoff.watchdogLimit)
        let frames = frameLink.finish(at: CACurrentMediaTime())
        let elapsed = now - flightStartedAt
        if flightTooShort(duration: elapsed, travel: flightTravel) {
            GioLog.record(.warn, "snapshot flight too short ms=\(Int((elapsed * 1000).rounded()))")
        }
        onFlightFinished?(flightToken, frames)
    }
}
