import CoreGraphics
import XCTest
@testable import GioCore

/// SM-27: a layer whose frame changes size never stretches its window. The
/// images are drawn at their own size, anchored top-left and clipped to the
/// animated frame; the start-size image crossfades into the target-size one
/// along the resize; without a target-size image the start image stays
/// unscaled over a fill sampled from its right edge (growing) or is cropped
/// (shrinking).
final class OverlayResizeTests: XCTestCase {
    private let column = CGSize(width: 800, height: 900)
    private let maximized = CGSize(width: 1600, height: 900)

    private func track(from: CGSize, to: CGSize, dx: CGFloat = 0) -> FlightTrack {
        FlightTrack(
            start: LayerGeometry(position: CGPoint(x: 400, y: 450), bounds: CGRect(origin: .zero, size: from)),
            end: LayerGeometry(
                position: CGPoint(x: to.width / 2 + dx, y: to.height / 2), bounds: CGRect(origin: .zero, size: to)
            )
        )
    }

    // MARK: mode

    func testAPureMoveNeedsNoResize() {
        XCTAssertNil(snapshotResizeMode(image: column, target: column, from: column, to: column))
        XCTAssertNil(snapshotResizeMode(image: column, target: nil, from: column, to: column))
        XCTAssertNil(
            snapshotResizeMode(image: CGSize(width: 801, height: 899), target: nil, from: column, to: column),
            "within the cache's 2 pt size tolerance"
        )
    }

    func testBothSizesCrossfadeOneSizeFillsWhenGrowingAndCropsWhenShrinking() {
        XCTAssertEqual(snapshotResizeMode(image: column, target: maximized, from: column, to: maximized), .crossfade)
        XCTAssertEqual(snapshotResizeMode(image: maximized, target: column, from: maximized, to: column), .crossfade)
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

    // MARK: crossfade curve

    func testTheCrossfadeIsDoneAtSixtyPercentOfTheResizeAndEasesBothEnds() {
        XCTAssertEqual(overlayCrossfadeSpan, 0.6)
        XCTAssertEqual(overlayCrossfadeWeight(progress: 0), 0)
        XCTAssertEqual(overlayCrossfadeWeight(progress: -0.2), 0)
        XCTAssertEqual(overlayCrossfadeWeight(progress: 0.3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(overlayCrossfadeWeight(progress: 0.6), 1)
        XCTAssertEqual(overlayCrossfadeWeight(progress: 1.3), 1)
        XCTAssertLessThan(overlayCrossfadeWeight(progress: 0.01), 0.002, "no visible start: zero slope")
        XCTAssertGreaterThan(overlayCrossfadeWeight(progress: 0.59), 0.998, "no visible stop: zero slope")
        var previous = -1.0
        for step in 0...100 {
            let weight = overlayCrossfadeWeight(progress: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(weight, previous)
            previous = weight
        }
    }

    func testProgressFollowsTheLargestSizeChangeAndClamps() {
        let grow = track(from: column, to: maximized, dx: 300)
        var geometry = grow.start
        XCTAssertEqual(overlayResizeProgress(track: grow, geometry: geometry), 0)
        geometry.bounds.size.width = 1200
        geometry.position.x = 9999
        XCTAssertEqual(overlayResizeProgress(track: grow, geometry: geometry), 0.5, "size, not position")
        geometry.bounds.size.width = 1650
        XCTAssertEqual(overlayResizeProgress(track: grow, geometry: geometry), 1, "overshoot clamps")
        geometry.bounds.size.width = 700
        XCTAssertEqual(overlayResizeProgress(track: grow, geometry: geometry), 0, "a carried velocity away clamps")
        XCTAssertEqual(overlayResizeProgress(track: grow, geometry: grow.end), 1)
    }

    func testWithoutASizeChangeProgressFollowsTheMoveAndANullTrackIsDone() {
        let move = track(from: column, to: column, dx: 200)
        var geometry = move.start
        geometry.position.x += 50
        XCTAssertEqual(overlayResizeProgress(track: move, geometry: geometry), 0.25, accuracy: 1e-12)
        let still = track(from: column, to: column)
        XCTAssertEqual(overlayResizeProgress(track: still, geometry: still.start), 1)
    }

    // MARK: crossfade state

    func testANewTargetImageFadesInOverTheOpaqueStartImage() {
        let base = OverlayCrossfade()
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(base.opacities(at: 0), [1])
        XCTAssertEqual(base.opacities(at: 1), [1])
        let fade = base.retargeted(at: 0, toward: 1)
        XCTAssertEqual(fade.count, 2)
        XCTAssertEqual(fade.opacities(at: 0), [1, 0])
        XCTAssertEqual(fade.opacities(at: 0.3)[1], 0.5, accuracy: 1e-12)
        XCTAssertEqual(fade.opacities(at: 0.6), [1, 1])
        XCTAssertEqual(fade.opacities(at: 1), [1, 1], "the last frame shows the target image (no pop at the hand-off)")
        XCTAssertEqual(base.retargeted(at: 0, toward: 0), base, "the start image is the target: nothing fades")
    }

    func testARetargetBackToTheStartImageFadesOutFromWhereItIs() {
        let fade = OverlayCrossfade().retargeted(at: 0, toward: 1)
        let back = fade.retargeted(at: 0.3, toward: 0)
        XCTAssertEqual(back.opacities(at: 0)[1], 0.5, accuracy: 1e-12, "continuous: no pop")
        XCTAssertEqual(back.opacities(at: 1), [1, 0])
    }

    func testARetargetToTheSameImageContinuesTheFade() {
        let fade = OverlayCrossfade().retargeted(at: 0, toward: 1)
        let now = fade.opacities(at: 0.15)[1]
        let onward = fade.retargeted(at: 0.15, toward: 1)
        XCTAssertEqual(onward.opacities(at: 0)[1], now, accuracy: 1e-12)
        XCTAssertEqual(onward.opacities(at: 1), [1, 1])
    }

    func testAThirdImageFadesInOnTopAndTheOthersStay() {
        let fade = OverlayCrossfade().retargeted(at: 0, toward: 1)
        let third = fade.retargeted(at: 0.3, toward: 2)
        XCTAssertEqual(third.count, 3)
        let start = third.opacities(at: 0)
        XCTAssertEqual(start[0], 1)
        XCTAssertEqual(start[1], 0.5, accuracy: 1e-12)
        XCTAssertEqual(start[2], 0)
        XCTAssertEqual(third.opacities(at: 1)[2], 1)
        let middle = fade.retargeted(at: 0.3, toward: 1).retargeted(at: 0.6, toward: 0)
        XCTAssertEqual(middle.opacities(at: 1), [1, 0], "every face above the target fades out")
    }

    func testAGrowingTargetThatCoversTheFlightIsOpaqueUnderTheFadingStartImage() {
        // Live: growing with the target image fading in on top showed the
        // backdrop (a black box) beside the start image until the fade ended.
        let grow = OverlayCrossfade().retargeted(at: 0, toward: 1, underlay: true)
        XCTAssertEqual(grow.order, [1, 0], "the target image is drawn under the start image")
        XCTAssertEqual(grow.opacities(at: 0), [1, 1], "every point of the growing frame is covered from the first frame")
        XCTAssertEqual(grow.opacities(at: 0.3)[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(grow.opacities(at: 0.6), [0, 1])
        XCTAssertEqual(grow.opacities(at: 1), [0, 1], "the last frame shows the target image alone")
    }

    func testShrinkingBackOverAnUnderlaidTargetFadesTheStartImageInOnTop() {
        let grow = OverlayCrossfade().retargeted(at: 0, toward: 1, underlay: true)
        let back = grow.retargeted(at: 0.3, toward: 0)
        XCTAssertEqual(back.order, [1, 0])
        XCTAssertEqual(back.opacities(at: 0)[0], 0.5, accuracy: 1e-12, "continuous: no pop")
        XCTAssertEqual(back.opacities(at: 0)[1], 1, "the larger image keeps covering the shrinking frame")
        XCTAssertEqual(back.opacities(at: 1), [1, 1])
        let again = back.retargeted(at: 0.3, toward: 1)
        XCTAssertEqual(again.opacities(at: 1), [0, 1], "growing again fades the image above it out")
    }

    func testOnlyAnImageAsLargeAsEveryFrameOfTheFlightCoversIt() {
        XCTAssertTrue(overlayFaceCovers(image: maximized, start: column, end: maximized))
        XCTAssertFalse(overlayFaceCovers(image: column, start: maximized, end: column), "shrinking: the start image covers")
        XCTAssertTrue(overlayFaceCovers(image: CGSize(width: maximized.width - 1, height: maximized.height), start: column, end: maximized),
                      "within the cache's 2 pt")
    }

    func testWithoutAnImageOfTheNewSizeTheClosestFaceWins() {
        XCTAssertEqual(overlayClosestFace([column, maximized], to: CGSize(width: 1500, height: 900)), 1)
        XCTAssertEqual(overlayClosestFace([column, maximized], to: CGSize(width: 900, height: 900)), 0)
        XCTAssertEqual(overlayClosestFace([column], to: maximized), 0)
        XCTAssertEqual(overlayClosestFace([column, column], to: column), 0, "ties keep the lower face")
    }

    // MARK: keyframes

    func testOpacityKeyframesFollowTheSpringAndLandOnTheTarget() throws {
        let grow = track(from: column, to: maximized)
        let keyframes = flightKeyframes(track: grow, spring: .niri, rate: 120)
        let values = overlayCrossfadeKeyframes(
            OverlayCrossfade().retargeted(at: 0, toward: 1), track: grow, keyframes: keyframes
        )
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], Array(repeating: 1, count: keyframes.times.count), "the base stays opaque")
        let fade = values[1]
        XCTAssertEqual(fade.count, keyframes.times.count)
        XCTAssertEqual(fade.first, 0)
        XCTAssertEqual(fade.last, 1)
        for (index, value) in fade.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(value, fade[index - 1] - 1e-12)
        }
        let opaque = try XCTUnwrap(fade.firstIndex { $0 >= 1 })
        XCTAssertLessThan(
            keyframes.times[opaque], 0.35, "the spring covers 60 % of the resize early: the target image shows for most of the flight"
        )
        XCTAssertGreaterThan(fade.filter { $0 > 0 && $0 < 1 }.count, 4, "a dissolve over several frames, not a pop")
    }

    func testARetargetMidFlightKeepsTheOpacityContinuous() {
        let grow = track(from: column, to: maximized)
        let crossfade = OverlayCrossfade().retargeted(at: 0, toward: 1)
        let elapsed = 0.03
        let now = grow.state(at: elapsed, spring: .niri).geometry
        let progress = overlayResizeProgress(track: grow, geometry: now)
        let before = crossfade.opacities(at: progress)
        // Alt+L during the maximize: same size, the column moves on.
        var end = grow.end
        end.position.x += 400
        let next = grow.retargeted(to: end, at: elapsed, spring: .niri)
        let continued = crossfade.retargeted(at: progress, toward: 1)
        let values = overlayCrossfadeKeyframes(
            continued, track: next, keyframes: flightKeyframes(track: next, spring: .niri, rate: 120)
        )
        XCTAssertEqual(values[1].first ?? -1, before[1], accuracy: 1e-9)
        XCTAssertEqual(values[1].last, 1)
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

    func testTheEdgeLineRunsDownTheRightEdgeInsideTheBorderAndCorners() throws {
        let line = try XCTUnwrap(snapshotEdgeLine(pixelWidth: 1600, pixelHeight: 1800, pixelsPerPoint: 2))
        // 2 pt in from the right edge (past the window's 1 px rim), the
        // rounded corners (10 pt) skipped; image pixels, top-left origin.
        XCTAssertEqual(line, CGRect(x: 1595, y: 20, width: 1, height: 1760))
        XCTAssertEqual(
            snapshotEdgeLine(pixelWidth: 400, pixelHeight: 300, pixelsPerPoint: 1),
            CGRect(x: 397, y: 10, width: 1, height: 280)
        )
        XCTAssertNil(snapshotEdgeLine(pixelWidth: 2, pixelHeight: 300, pixelsPerPoint: 1), "too narrow")
        XCTAssertNil(snapshotEdgeLine(pixelWidth: 400, pixelHeight: 20, pixelsPerPoint: 1), "nothing between the corners")
    }

    /// The median, not the mean: a title bar, a status bar or a line of text
    /// crossing the edge is a minority and does not tint the fill.
    func testTheFillIsTheMedianOfTheOpaqueEdgeSamples() throws {
        let white: UInt32 = 0xF0F0_F0FF
        let blue: UInt32 = 0x2060_C0FF
        let clear: UInt32 = 0
        let samples = Array(repeating: white, count: 40) + Array(repeating: blue, count: 20) + Array(repeating: clear, count: 30)
        let fill = try XCTUnwrap(snapshotEdgeFill(samples: samples))
        XCTAssertEqual(fill, ThemeColor(red: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF0 / 255.0))
    }

    func testPremultipliedSamplesAreUnpremultipliedAndTransparentOnesIgnored() throws {
        // 50 % alpha, premultiplied 0x40: the colour is half bright.
        let fill = try XCTUnwrap(snapshotEdgeFill(samples: [0x4040_4080]))
        XCTAssertEqual(fill.red, 0.5, accuracy: 1e-9)
        XCTAssertNil(snapshotEdgeFill(samples: [0x1010_1020, 0]), "a see-through edge gets no fill")
        XCTAssertNil(snapshotEdgeFill(samples: []))
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
