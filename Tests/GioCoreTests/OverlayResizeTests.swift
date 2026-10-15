import CoreGraphics
import XCTest
@testable import GioCore

/// SM-27: a layer whose frame changes size never stretches its window. The
/// images are drawn at their own size, anchored top-left and clipped to the
/// animated frame; SM-32: the target-size image replaces the start-size one
/// at the start of the resize (no dissolve); without a target-size image the
/// start image stays unscaled over a fill of its most common colour
/// (growing; SM-30) or is cropped (shrinking).
final class OverlayResizeTests: XCTestCase {
    private let column = CGSize(width: 800, height: 900)
    private let maximized = CGSize(width: 1600, height: 900)

    // MARK: mode

    func testAPureMoveNeedsNoResize() {
        XCTAssertNil(snapshotResizeMode(image: column, target: column, from: column, to: column))
        XCTAssertNil(snapshotResizeMode(image: column, target: nil, from: column, to: column))
        XCTAssertNil(
            snapshotResizeMode(image: CGSize(width: 801, height: 899), target: nil, from: column, to: column),
            "within the cache's 2 pt size tolerance"
        )
    }

    func testBothSizesSwapOneSizeFillsWhenGrowingAndCropsWhenShrinking() {
        XCTAssertEqual(snapshotResizeMode(image: column, target: maximized, from: column, to: maximized), .swap)
        XCTAssertEqual(snapshotResizeMode(image: maximized, target: column, from: maximized, to: column), .swap)
        XCTAssertEqual(snapshotResizeMode(image: column, target: nil, from: column, to: maximized), .fill)
        XCTAssertEqual(snapshotResizeMode(image: maximized, target: nil, from: maximized, to: column), .crop)
        XCTAssertEqual(
            snapshotResizeMode(image: column, target: column, from: column, to: maximized), .fill,
            "a target image of the start image's size is no second image"
        )
        let wideShort = CGSize(width: 1000, height: 600)
        XCTAssertEqual(
            snapshotResizeMode(image: column, target: nil, from: column, to: wideShort), .fill,
            "any axis the image does not cover needs the fill"
        )
    }

    /// The SM-11 case (no image of the start size, a fresh one of the other
    /// size) used to be scaled to the layer; it is drawn at its own size now.
    func testAnImageOfAnotherSizeOnAMoveIsCroppedOrFilledNeverScaled() {
        XCTAssertEqual(snapshotResizeMode(image: maximized, target: nil, from: column, to: column), .crop)
        XCTAssertEqual(snapshotResizeMode(image: column, target: nil, from: maximized, to: maximized), .fill)
    }

    // MARK: faces

    /// Live 2026-10-15 (60 fps recording of Alt+F on Postman): the dissolve
    /// between the start image and the image of the new size showed both
    /// layouts on top of each other for a few frames, which reads as a blink.
    /// The image of the new size replaces the start image at once: no frame
    /// ever mixes two images of different sizes.
    func testShowingTheImageOfTheNewSizeHidesEveryOtherFaceAtOnce() {
        let base = OverlayFaces()
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(base.opacities, [1])
        let grow = base.showing(1)
        XCTAssertEqual(grow.count, 2)
        XCTAssertEqual(grow.opacities, [0, 1], "no intermediate opacity: never two layouts at once")
        XCTAssertEqual(grow.showing(0).opacities, [1, 0], "back to the start image, at once")
        XCTAssertEqual(grow.showing(2).opacities, [0, 0, 1], "a third image replaces the shown one")
        XCTAssertEqual(base.showing(0), base, "the start image is the target: nothing changes")
    }

    func testWithoutAnImageOfTheNewSizeTheClosestFaceWins() {
        XCTAssertEqual(overlayClosestFace([column, maximized], to: CGSize(width: 1500, height: 900)), 1)
        XCTAssertEqual(overlayClosestFace([column, maximized], to: CGSize(width: 900, height: 900)), 0)
        XCTAssertEqual(overlayClosestFace([column], to: maximized), 0)
        XCTAssertEqual(overlayClosestFace([column, column], to: column), 0, "ties keep the lower face")
    }

    // MARK: drawing

    func testOnlyAPureMoveWithAMatchingImageDrawsTheImageDirectly() {
        XCTAssertTrue(overlayDrawsDirect(image: column, faces: 1, start: column, end: column))
        XCTAssertTrue(overlayDrawsDirect(image: CGSize(width: 802, height: 900), faces: 1, start: column, end: column))
        XCTAssertFalse(overlayDrawsDirect(image: column, faces: 1, start: column, end: maximized))
        XCTAssertFalse(overlayDrawsDirect(image: maximized, faces: 1, start: column, end: column))
        XCTAssertFalse(overlayDrawsDirect(image: column, faces: 2, start: column, end: column))
    }

    /// The clip's bounds put its top-left corner at its own origin (y up), so
    /// images and fills placed there stay on the window's top-left corner
    /// while the bounds grow or shrink.
    func testImagesAndFillHangFromTheTopLeftCornerOfTheClip() {
        let clip = overlayClipBounds(column)
        XCTAssertEqual(clip, CGRect(x: 0, y: -900, width: 800, height: 900))
        XCTAssertEqual(clip.maxY, 0)
        let frames = overlayFaceFrames(image: column, reach: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(frames.image, CGRect(x: 0, y: -900, width: 800, height: 900), "the image's own size")
        XCTAssertEqual(frames.fill, CGRect(x: 0, y: -1000, width: 1600, height: 1000))
        XCTAssertEqual(frames.image.maxY, 0)
        XCTAssertEqual(frames.fill.maxY, 0)
        XCTAssertEqual(frames.image.minX, 0)
    }

    func testReachIsTheLargestFrameOfTheFlight() {
        XCTAssertEqual(
            overlayReach([column, CGSize(width: 1610, height: 880), CGSize(width: 1600, height: 905)]),
            CGSize(width: 1610, height: 905)
        )
        XCTAssertEqual(overlayReach([]), .zero)
    }

    // MARK: fill

    /// SM-30: the most common colour, not the median of the right edge: a
    /// live Slack maximize showed a huge purple box (the frame along its right
    /// edge). Title bars, borders, sidebars and text are minorities.
    func testTheFillIsTheMostCommonColourOfTheOpaqueSamples() throws {
        let content: UInt32 = 0x1A1D_21FF
        let frame: UInt32 = 0x3F0E_40FF
        let text: UInt32 = 0xD1D2_D3FF
        let clear: UInt32 = 0
        let samples = Array(repeating: frame, count: 30) + Array(repeating: content, count: 45)
            + Array(repeating: text, count: 20) + Array(repeating: clear, count: 5)
        let fill = try XCTUnwrap(snapshotContentFill(samples: samples))
        XCTAssertEqual(fill.red, 0x1A / 255.0, accuracy: 1e-9)
        XCTAssertEqual(fill.green, 0x1D / 255.0, accuracy: 1e-9)
        XCTAssertEqual(fill.blue, 0x21 / 255.0, accuracy: 1e-9)
    }

    /// Antialiased shades of one background fall in one bucket; the fill is
    /// their mean, so noise does not split the content background.
    func testNearlyEqualShadesCountAsOneColourAndAverage() throws {
        let shades: [UInt32] = [0x2020_20FF, 0x2222_22FF, 0x2121_21FF]
        let border: UInt32 = 0x8080_80FF
        let samples = shades.flatMap { Array(repeating: $0, count: 10) } + Array(repeating: border, count: 20)
        let fill = try XCTUnwrap(snapshotContentFill(samples: samples))
        XCTAssertEqual(fill.red, 0x21 / 255.0, accuracy: 1e-9)
    }

    func testPremultipliedSamplesAreUnpremultipliedAndASeeThroughCaptureHasNoFill() throws {
        // 50 % alpha, premultiplied 0x40: the colour is half bright.
        let fill = try XCTUnwrap(snapshotContentFill(samples: [0x4040_4080]))
        XCTAssertEqual(fill.red, 0.5, accuracy: 1e-9)
        XCTAssertNil(snapshotContentFill(samples: [0x1010_1020, 0]), "a see-through capture gets no fill")
        XCTAssertNil(snapshotContentFill(samples: [0xFFFF_FFFF, 0, 0]), "mostly see-through: no fill")
        XCTAssertNil(snapshotContentFill(samples: []))
    }

    // MARK: SM-30 fresh face

    /// A fresh capture of the landing size arrives mid-flight: it goes on top,
    /// opaque (the overlay fades it in over the shown image of the same size);
    /// a later retarget shows one face alone again.
    func testAFreshFaceGoesOnTopOpaqueAndARetargetShowsOneFaceAlone() {
        let fresh = OverlayFaces().showing(1).freshened()
        XCTAssertEqual(fresh.count, 3)
        XCTAssertEqual(fresh.opacities, [0, 1, 1], "on top, the shown face stays under it")
        XCTAssertEqual(fresh.showing(0).opacities, [1, 0, 0])
    }

    func testAFaceIsTheImageAtItsCapturedSizeWithItsFill() {
        let fill = ThemeColor(red: 1, green: 1, blue: 1)
        let entry = SnapshotCacheEntry(
            image: "s", frame: CGRect(x: 30, y: 40, width: 800, height: 900), capturedAt: 1, lastUsed: 1, pixels: 1,
            fill: fill
        )
        XCTAssertEqual(entry.face, SnapshotFace(image: "s", size: column, fill: fill))
    }
}
