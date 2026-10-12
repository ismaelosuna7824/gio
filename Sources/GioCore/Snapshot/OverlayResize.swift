import CoreGraphics
import Foundation

// SM-27: a layer whose frame changes size never stretches its window
// (live report: "como son imágenes ... se ve un poco como que se estira").
// Like niri's resize: every image is drawn at its own size, hanging from the
// window's top-left corner and clipped to the animated frame (corner radius
// and shadow unchanged); the start-size image crossfades into the
// target-size one along the resize. Without a target-size image the start
// image stays unscaled: what it does not cover shows a flat fill (SM-30: the
// most common colour of its right half, `snapshotContentFill`; SM-27 sampled
// its right edge), and what the frame no longer covers is cut off
// (shrinking). A flat fill was chosen over stretching the last pixel
// column/row (a 9-slice): a line of text, a scrollbar or a sidebar crossing
// the edge would be smeared into streaks, which reads as stretching again.
// SM-30: a fresh capture of the landing size replaces it mid-flight.

/// How a layer shows a window whose frame and image sizes differ.
public enum SnapshotResizeMode: String, Equatable, Sendable {
    /// Start image fading into the image of the target size, both unscaled.
    case crossfade
    /// One image, unscaled, over its fill where the frame outgrows it.
    case fill
    /// One image, unscaled, cut off by a frame smaller than it.
    case crop
}

private func sameSize(_ a: CGSize, _ b: CGSize, tolerance: CGFloat) -> Bool {
    abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// The mode of a layer drawing an `image` (its own size, points) from a
/// frame of size `from` to one of size `to`, with `target` the size of the
/// target-size image when one is cached. Nil: the image fits both frames
/// (a pure move; `tolerance` is the cache's size match).
public func snapshotResizeMode(
    image: CGSize, target: CGSize?, from: CGSize, to: CGSize, tolerance: CGFloat = 2
) -> SnapshotResizeMode? {
    if let target, !sameSize(target, image, tolerance: tolerance) {
        return .crossfade
    }
    if sameSize(image, from, tolerance: tolerance), sameSize(image, to, tolerance: tolerance) {
        return nil
    }
    let reach = CGSize(width: max(from.width, to.width), height: max(from.height, to.height))
    if image.width < reach.width - tolerance || image.height < reach.height - tolerance {
        return .fill
    }
    return .crop
}

// MARK: crossfade

/// Fraction of the resize (not of the time) by which the target-size image
/// is fully opaque. Gio's spring covers distance early (niri's default: 60 %
/// of an Alt+F within ~70 ms of a ~350 ms flight), so the dissolve lasts a
/// few frames (no pop) while the double exposure of two text layouts never
/// lingers, and the target image alone shows for the rest of the flight:
/// the last frame before the hand-off is the image of the size the real
/// window lands at.
public let overlayCrossfadeSpan = 0.6

/// Weight of the fade at `progress` of the resize: smoothstep over
/// `0...overlayCrossfadeSpan`, flat at both ends (no visible start or stop).
public func overlayCrossfadeWeight(progress: Double) -> Double {
    let x = min(max(progress / overlayCrossfadeSpan, 0), 1)
    return x * x * (3 - 2 * x)
}

/// How far `geometry` is along `track`, 0...1 (clamped: a spring overshoot
/// or a carried velocity away from the target never leaves the range). The
/// largest size change leads; a track that keeps its size follows its
/// largest move; a track that does neither is done.
public func overlayResizeProgress(track: FlightTrack, geometry: LayerGeometry) -> Double {
    let sizes: [(start: CGFloat, end: CGFloat, now: CGFloat)] = [
        (track.start.bounds.width, track.end.bounds.width, geometry.bounds.width),
        (track.start.bounds.height, track.end.bounds.height, geometry.bounds.height),
    ]
    let moves: [(start: CGFloat, end: CGFloat, now: CGFloat)] = [
        (track.start.position.x, track.end.position.x, geometry.position.x),
        (track.start.position.y, track.end.position.y, geometry.position.y),
    ]
    for axes in [sizes, moves] {
        guard let lead = axes.max(by: { abs($0.start - $0.end) < abs($1.start - $1.end) }),
              abs(lead.start - lead.end) >= SpringParameters.minimumThreshold
        else {
            continue
        }
        let progress = 1 - Double((lead.now - lead.end) / (lead.start - lead.end))
        return min(max(progress, 0), 1)
    }
    return 1
}

/// The images (faces) of one layer, their drawing order (`order`, face
/// indices bottom to top) and the opacity of each at the start and at the
/// end of the current track. The bottom face stays opaque, so nothing behind
/// the window shows through mid-fade; a face fades in on top of it, or out.
/// SM-28: a new face that covers every frame of the flight (a grow) goes
/// under the others, opaque at once, and the faces above it fade out: the
/// growing frame never shows what is behind the window.
public struct OverlayCrossfade: Equatable, Sendable {
    public private(set) var from: [Double]
    public private(set) var to: [Double]
    public private(set) var order: [Int]

    /// One face, opaque.
    public init() {
        from = [1]
        to = [1]
        order = [0]
    }

    public var count: Int { from.count }

    /// Every face's opacity at `progress` of the current track.
    public func opacities(at progress: Double) -> [Double] {
        let weight = overlayCrossfadeWeight(progress: progress)
        return zip(from, to).map { $0 + ($1 - $0) * weight }
    }

    /// A new track from `progress` of the current one, fading to face
    /// `index` (`count`: a new face, on top and transparent at first, or
    /// with `underlay` at the bottom and opaque). The faces drawn above it
    /// fade out, it fades in, the ones below keep their opacity (hidden by it
    /// at the end). Continuous: the new track starts at the opacities this
    /// one has at `progress`.
    public func retargeted(at progress: Double, toward index: Int, underlay: Bool = false) -> OverlayCrossfade {
        var current = opacities(at: progress)
        var crossfade = self
        if index >= current.count {
            current.append(underlay ? 1 : 0)
            if underlay {
                crossfade.order.insert(current.count - 1, at: 0)
            } else {
                crossfade.order.append(current.count - 1)
            }
        }
        let face = min(index, current.count - 1)
        let position = crossfade.order.firstIndex(of: face)!
        var next = current
        for above in crossfade.order[(position + 1)...] {
            next[above] = 0
        }
        next[face] = 1
        crossfade.from = current
        crossfade.to = next
        return crossfade
    }

    /// SM-30: a fresh image of the landing size arrived (`count`: a new
    /// face) at `progress` of the current track. It goes on top and fades in
    /// over `overlayFreshFadeDuration` (timed: the resize is nearly done by
    /// then, a fade along it would pop); every other face holds the opacity
    /// it has now. A later retarget starts from there, continuous.
    public func freshened(at progress: Double) -> OverlayCrossfade {
        var crossfade = self
        let current = opacities(at: progress) + [1]
        crossfade.order.append(current.count - 1)
        crossfade.from = current
        crossfade.to = current
        return crossfade
    }
}

/// SM-30: how long a fresh face fades in on top of a layer (eased).
public let overlayFreshFadeDuration: TimeInterval = 0.1

/// SM-28: an image as large as every frame of a flight from `start` to
/// `end` (within the cache's 2 pt; a spring overshoot is not counted): drawn
/// under the others, it leaves nothing of the frame uncovered.
public func overlayFaceCovers(image: CGSize, start: CGSize, end: CGSize, tolerance: CGFloat = 2) -> Bool {
    let reach = overlayReach([start, end])
    return image.width >= reach.width - tolerance && image.height >= reach.height - tolerance
}

/// The face to fade to when no image of the new size is cached: the one
/// whose size is closest to it (ties: the lower face). The layer then lands
/// on one image, unscaled over its fill or cut off, instead of a mix.
public func overlayClosestFace(_ sizes: [CGSize], to target: CGSize) -> Int {
    var best = 0
    var distance = CGFloat.infinity
    for (index, size) in sizes.enumerated() {
        let candidate = abs(size.width - target.width) + abs(size.height - target.height)
        if candidate < distance {
            best = index
            distance = candidate
        }
    }
    return best
}

/// Every face's opacity at each keyframe of `track` (one array per face,
/// index-aligned with `keyframes.times`): sampled from the same spring as
/// the geometry, so the fade follows the resize and lands exactly on `to`.
public func overlayCrossfadeKeyframes(
    _ crossfade: OverlayCrossfade, track: FlightTrack, keyframes: FlightKeyframes
) -> [[Double]] {
    var values = Array(repeating: [Double](), count: crossfade.count)
    for geometry in keyframes.geometries {
        let opacities = crossfade.opacities(at: overlayResizeProgress(track: track, geometry: geometry))
        for face in opacities.indices {
            values[face].append(opacities[face])
        }
    }
    return values
}

// MARK: drawing

/// A layer may draw its one image straight into its frame (the layer's own
/// contents, as before SM-27) only when that image fits the start and end
/// frames (within the cache's 2 pt): a pure move. Anything else draws faces.
public func overlayDrawsDirect(
    image: CGSize, faces: Int, start: CGSize, end: CGSize, tolerance: CGFloat = 2
) -> Bool {
    faces == 1 && sameSize(image, start, tolerance: tolerance) && sameSize(image, end, tolerance: tolerance)
}

/// Bounds of the clipping layer for a frame of `size`: its top-left corner
/// at the layer's own origin (y up, so the bounds hang below it). Sublayers
/// placed from that origin stay on the window's top-left corner while the
/// bounds grow or shrink (Cocoa/AX conversion stays in `overlayLayerGeometry`).
public func overlayClipBounds(_ size: CGSize) -> CGRect {
    CGRect(x: 0, y: -size.height, width: size.width, height: size.height)
}

/// One face inside the clip: the image at its own size and the fill under
/// it out to `reach` (the largest frame of the flight), both hanging from
/// the top-left corner.
public func overlayFaceFrames(image: CGSize, reach: CGSize) -> (image: CGRect, fill: CGRect) {
    (overlayClipBounds(image), overlayClipBounds(reach))
}

/// The largest width and height among `sizes` (zero for none).
public func overlayReach(_ sizes: some Sequence<CGSize>) -> CGSize {
    sizes.reduce(.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
}

// MARK: fill

/// SM-30: the fill of a capture (where the frame outgrows the image) from
/// samples of its right half (packed premultiplied RGBA, alpha in the low
/// byte): the most common colour (channels in 16 levels; ties: the lower
/// bucket), the mean of its samples, unpremultiplied; samples less than half
/// opaque are ignored. Live, SM-27's median of the right edge was Slack's
/// purple frame and filled a maximize with a huge purple box; the content
/// pane (the editor, the message list, the page) has the largest area, and
/// the right half leaves out left sidebars, which keep their width when a
/// window grows. Nil when fewer than half of the samples are opaque (a
/// see-through window: the fill stays clear, like the window).
public func snapshotContentFill(samples: [UInt32]) -> ThemeColor? {
    var buckets: [Int: (count: Int, sum: (Double, Double, Double))] = [:]
    var opaque = 0
    for sample in samples {
        let alpha = Double(sample & 0xFF)
        guard alpha >= 0x80 else {
            continue
        }
        opaque += 1
        let channels = [24, 16, 8].map { min(Double((sample >> UInt32($0)) & 0xFF) / alpha, 1) }
        let key = channels.reduce(0) { $0 << 4 | min(Int($1 * 16), 15) }
        let bucket = buckets[key] ?? (0, (0, 0, 0))
        buckets[key] = (
            bucket.count + 1, (bucket.sum.0 + channels[0], bucket.sum.1 + channels[1], bucket.sum.2 + channels[2])
        )
    }
    guard opaque > 0, opaque * 2 >= samples.count,
          let winner = buckets.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) })
    else {
        return nil
    }
    let count = Double(winner.value.count)
    return ThemeColor(red: winner.value.sum.0 / count, green: winner.value.sum.1 / count, blue: winner.value.sum.2 / count)
}

/// One image a window layer can show: the image, its own size in points
/// (the frame it was captured at; SM-22 half-resolution images too) and its
/// fill (`snapshotContentFill`).
public struct SnapshotFace<Image> {
    public let image: Image
    public let size: CGSize
    public let fill: ThemeColor?

    public init(image: Image, size: CGSize, fill: ThemeColor?) {
        self.image = image
        self.size = size
        self.fill = fill
    }
}

extension SnapshotFace: Equatable where Image: Equatable {}
extension SnapshotFace: @unchecked Sendable {}
