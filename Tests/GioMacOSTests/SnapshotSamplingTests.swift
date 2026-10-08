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
}
