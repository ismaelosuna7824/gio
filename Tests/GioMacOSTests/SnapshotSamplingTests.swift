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

    // MARK: SM-27 edge fill

    /// A window with a dark title bar, a blue status bar and a 1 px rim on
    /// its right edge: the fill is the content background.
    func testTheEdgeFillIsTheContentBackgroundBesideBarsAndRim() throws {
        let window = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: 272, width: 400, height: 28))
            context.setFillColor(CGColor(red: 0, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 22))
            context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 399, y: 0, width: 1, height: 300))
        }
        let samples = snapshotEdgeSamples(of: window, pixelsPerPoint: 1)
        XCTAssertEqual(samples.count, 64)
        let fill = try XCTUnwrap(snapshotEdgeFill(samples: samples))
        XCTAssertEqual(fill.red, 1, accuracy: 2 / 255)
        XCTAssertEqual(fill.green, 1, accuracy: 2 / 255)
        XCTAssertEqual(fill.blue, 1, accuracy: 2 / 255)
    }

    func testATransparentOrTinyCaptureHasNoEdgeFill() {
        let clear = image(width: 300, height: 200) { _ in }
        XCTAssertNil(snapshotEdgeFill(samples: snapshotEdgeSamples(of: clear, pixelsPerPoint: 1)))
        let dot = image(width: 1, height: 1) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(snapshotEdgeSamples(of: dot, pixelsPerPoint: 1), [])
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
