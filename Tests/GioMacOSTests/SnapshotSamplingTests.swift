import CoreGraphics
import XCTest
@testable import GioCore
@testable import GioMacOS

/// SM-09: the blank guard samples a 5x5 grid of a capture plus five samples
/// along each edge, and hands the packed pixels to the pure decision. SM-10:
/// a blank verdict is confirmed by a coarse 64x64 scan, so a sparse window
/// (uniform background, little content) is not mistaken for an unpainted one.
final class SnapshotSamplingTests: XCTestCase {
    private func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    func testTransparentCaptureSamplesAsBlank() {
        let clear = image(width: 300, height: 200) { _ in }
        let samples = snapshotSamples(of: clear)
        XCTAssertEqual(samples.count, 45)
        XCTAssertTrue(snapshotLooksBlank(samples: samples))
    }

    func testFlatColourSamplesAsBlank() {
        let white = image(width: 300, height: 200) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        XCTAssertTrue(snapshotLooksBlank(samples: snapshotSamples(of: white)))
        XCTAssertTrue(snapshotLooksBlank(samples: snapshotSamples(of: white), dense: { snapshotDenseSamples(of: white) }))
    }

    /// A terminal with one prompt line: the sparse grid misses the text, the
    /// dense scan does not.
    func testASparseWindowWithOnePromptLineIsNotBlank() {
        let terminal = image(width: 800, height: 900) { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 900))
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 12, y: 870, width: 60, height: 16))
        }
        let sparse = snapshotSamples(of: terminal)
        XCTAssertTrue(snapshotLooksBlank(samples: sparse), "the sparse grid misses one prompt line")
        var denseCalls = 0
        XCTAssertFalse(snapshotLooksBlank(samples: sparse, dense: {
            denseCalls += 1
            return snapshotDenseSamples(of: terminal)
        }))
        XCTAssertEqual(denseCalls, 1)
        XCTAssertEqual(snapshotDenseSamples(of: terminal).count, 64 * 64)
    }

    func testTheDenseScanRunsOnlyWhenTheSparseSamplesLookBlank() {
        let titled = image(width: 300, height: 200) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 199, width: 300, height: 1))
        }
        var denseCalls = 0
        XCTAssertFalse(snapshotLooksBlank(samples: snapshotSamples(of: titled), dense: {
            denseCalls += 1
            return []
        }))
        XCTAssertEqual(denseCalls, 0)
        // A transparent capture is confirmed the same way (a transparent
        // terminal with one prompt line is content too).
        let clear = image(width: 300, height: 200) { _ in }
        XCTAssertTrue(snapshotLooksBlank(samples: snapshotSamples(of: clear), dense: {
            denseCalls += 1
            return snapshotDenseSamples(of: clear)
        }))
        XCTAssertEqual(denseCalls, 1)
    }

    func testAOnePixelTitleBarAtTheEdgeCountsAsContent() {
        let titled = image(width: 300, height: 200) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 199, width: 300, height: 1))
        }
        let samples = snapshotSamples(of: titled)
        XCTAssertEqual(samples.count, 45)
        XCTAssertFalse(snapshotLooksBlank(samples: samples), "the edge row is sampled")
    }

    func testTinyImagesStillSample() {
        let dot = image(width: 1, height: 1) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(snapshotSamples(of: dot).count, 45)
    }

    // MARK: SM-30 content fill

    /// Slack-like: a purple frame along the top and the right edge and a
    /// purple sidebar on the left around a dark content pane. SM-27 sampled
    /// the right edge (a live maximize showed a huge purple box); the most
    /// common colour of the right half is the content background.
    func testTheFillIsTheMostCommonColourOfTheRightHalfNotItsFrameOrSidebar() throws {
        let window = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.11, blue: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(red: 0.25, green: 0.05, blue: 0.25, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 230, height: 300))
            context.fill(CGRect(x: 0, y: 260, width: 400, height: 40))
            context.fill(CGRect(x: 388, y: 0, width: 12, height: 300))
            context.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
            for line in stride(from: 20, to: 240, by: 24) {
                context.fill(CGRect(x: 250, y: CGFloat(line), width: 110, height: 8))
            }
        }
        let samples = snapshotContentSamples(of: window)
        XCTAssertEqual(samples.count, 32 * 64)
        let fill = try XCTUnwrap(snapshotContentFill(samples: samples))
        // The test image is device RGB, the samples sRGB: the expected colour
        // goes through the same conversion.
        let pane = image(width: 40, height: 40) { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.11, blue: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let content = try XCTUnwrap(snapshotContentFill(samples: snapshotContentSamples(of: pane)))
        XCTAssertEqual(fill.red, content.red, accuracy: 2 / 255)
        XCTAssertEqual(fill.green, content.green, accuracy: 2 / 255)
        XCTAssertEqual(fill.blue, content.blue, accuracy: 2 / 255)
    }

    func testATransparentCaptureHasNoFill() {
        let clear = image(width: 300, height: 200) { _ in }
        XCTAssertNil(snapshotContentFill(samples: snapshotContentSamples(of: clear)))
    }

    // MARK: SM-30 stale layout

    /// A window shrunk from 400 to 200 px that still shows its old layout
    /// clipped to the new frame samples like the start image cut to 200 px;
    /// re-laid out (its right border moved to the new edge) it does not.
    func testAClippedOldLayoutSamplesLikeTheStartImageCutToTheNewSize() {
        func layout(_ context: CGContext, width: CGFloat) {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
            context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 300))
            context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: width - 40, y: 0, width: 40, height: 300))
            context.fill(CGRect(x: 0, y: 270, width: width, height: 30))
        }
        let start = image(width: 400, height: 300) { layout($0, width: 400) }
        let clipped = image(width: 200, height: 300) { layout($0, width: 400) }
        let relaid = image(width: 200, height: 300) { layout($0, width: 200) }
        let region = snapshotRegionPixels(
            CGSize(width: 200, height: 300), of: CGSize(width: 400, height: 300), pixelWidth: 400, pixelHeight: 300
        )
        let startRegion = snapshotRegionSamples(of: start, in: region)
        XCTAssertEqual(startRegion.count, 45)
        XCTAssertTrue(snapshotPaintStable(startRegion, snapshotSamples(of: clipped)))
        XCTAssertFalse(snapshotPaintStable(startRegion, snapshotSamples(of: relaid)))
        XCTAssertEqual(snapshotRegionSamples(of: start, in: CGRect(x: 500, y: 0, width: 10, height: 10)), [])
    }

    // MARK: SM-29 grown strips

    /// An editor grown from 300 to 400 px wide whose new right part is still
    /// an unpainted black box (Electron after a resize), then painted.
    func testTheStripAWindowGrewIntoReadsUnpaintedUntilItsContentArrives() {
        let background = ThemeColor(red: 0.12, green: 0.12, blue: 0.12)
        let strips = snapshotGrownStrips(
            from: CGSize(width: 300, height: 300), to: CGSize(width: 400, height: 300), pixelWidth: 400, pixelHeight: 300
        )
        XCTAssertEqual(strips.count, 1)
        let partial = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 300, y: 0, width: 100, height: 300))
        }
        let samples = snapshotStripSamples(of: partial, in: strips[0])
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(snapshotStripUnpainted(samples: samples, background: background))

        let painted = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 270, width: 400, height: 30))
        }
        XCTAssertFalse(snapshotStripUnpainted(samples: snapshotStripSamples(of: painted, in: strips[0]), background: background))
    }

    /// Strips are in image pixels with a top-left origin: a window grown
    /// downwards is judged on its bottom rows.
    func testTheStripOfAWindowGrownDownIsItsBottomRows() {
        let strips = snapshotGrownStrips(
            from: CGSize(width: 400, height: 200), to: CGSize(width: 400, height: 300), pixelWidth: 400, pixelHeight: 300
        )
        XCTAssertEqual(strips.count, 1)
        let grownDown = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 100, width: 400, height: 200))
            context.setFillColor(CGColor(red: 0, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 270, width: 400, height: 30))
        }
        XCTAssertTrue(
            snapshotStripUnpainted(samples: snapshotStripSamples(of: grownDown, in: strips[0]), background: nil),
            "the bottom 100 px are still transparent"
        )
    }
}
