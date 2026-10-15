import CoreGraphics
import Foundation

// SM-27: a layer whose frame changes size never stretches its window
// (live report: "como son imágenes ... se ve un poco como que se estira").
// Like niri's resize: every image is drawn at its own size, hanging from the
// window's top-left corner and clipped to the animated frame (corner radius
// and shadow unchanged). SM-32: the image of the target size replaces the
// start image at the start of the resize; SM-27's dissolve between them showed
// both layouts on top of each other for a few frames, which read as a blink
// (live, 2026-10-15, Alt+F on Postman). Without a target-size image the start
// image stays unscaled: what it does not cover shows a flat fill (SM-30: the
// most common colour of its right half, `snapshotContentFill`; SM-27 sampled
// its right edge), and what the frame no longer covers is cut off
// (shrinking). A flat fill was chosen over stretching the last pixel
// column/row (a 9-slice): a line of text, a scrollbar or a sidebar crossing
// the edge would be smeared into streaks, which reads as stretching again.
// SM-30: a fresh capture of the landing size replaces it mid-flight.

/// How a layer shows a window whose frame and image sizes differ.
public enum SnapshotResizeMode: String, Equatable, Sendable {
    /// The image of the target size, unscaled, in place of the start image
    /// from the first frame (SM-32).
    case swap
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
        return .swap
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

// MARK: faces

/// The images (faces) of one layer, drawn in index order (a new face goes on
/// top), and the opacity of each. One face shows at a time (SM-32): showing
/// another hides every other face at once, so no frame mixes two layouts.
/// SM-30's fresh face is the exception: it goes on top of the shown face
/// (both of the landing size) and the overlay fades it in.
public struct OverlayFaces: Equatable, Sendable {
    public private(set) var opacities: [Double]

    /// One face, opaque.
    public init() {
        opacities = [1]
    }

    public var count: Int { opacities.count }

    /// Face `index` alone (`count`: a new face, added on top).
    public func showing(_ index: Int) -> OverlayFaces {
        var faces = self
        let shown = min(index, count)
        faces.opacities = (0...max(count - 1, shown)).map { $0 == shown ? 1 : 0 }
        return faces
    }

    /// SM-30: a fresh image of the landing size arrived: a new face on top,
    /// opaque; every other face keeps its opacity (the overlay fades the new
    /// one in over the shown face).
    public func freshened() -> OverlayFaces {
        var faces = self
        faces.opacities.append(1)
        return faces
    }
}

/// SM-30: how long a fresh face fades in on top of a layer (eased).
public let overlayFreshFadeDuration: TimeInterval = 0.1

/// The face to show when no image of the new size is cached: the one
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
