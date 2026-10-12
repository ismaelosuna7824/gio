import CoreGraphics
import XCTest
@testable import GioCore

/// SM-27: a layer whose frame changes size never stretches its window. The
/// images are drawn at their own size, anchored top-left and clipped to the
/// animated frame; the start-size image crossfades into the target-size one
/// along the resize; without a target-size image the start image stays
/// unscaled over a fill of its most common colour (growing; SM-30) or is
/// cropped (shrinking).
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

    /// A fresh capture of the landing size arrives mid-flight: it goes on top
    /// and its fade is timed, not tied to the resize (nearly done by then);
    /// afterwards a retarget starts from it, continuous.
    func testAFreshFaceGoesOnTopOpaqueAndARetargetContinuesFromIt() {
        let fade = OverlayCrossfade().retargeted(at: 0, toward: 1, underlay: true)
        let fresh = fade.freshened(at: 0.3)
        XCTAssertEqual(fresh.count, 3)
        XCTAssertEqual(fresh.order, [1, 0, 2], "on top of every face")
        let held = fresh.opacities(at: 0)
        XCTAssertEqual(held[0], 0.5, accuracy: 1e-12, "the faces under it keep where they were")
        XCTAssertEqual(held[2], 1)
        XCTAssertEqual(fresh.opacities(at: 0.9), held, "nothing else fades along the resize")
        let back = fresh.retargeted(at: 0.95, toward: 0)
        XCTAssertEqual(back.opacities(at: 0)[2], 1, "a retarget starts where the fresh face is")
        XCTAssertEqual(back.opacities(at: 1)[2], 0, "and fades it out like any face above the target")
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
