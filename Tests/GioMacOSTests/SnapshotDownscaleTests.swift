import CoreGraphics
import XCTest
@testable import GioCore
@testable import GioMacOS

/// PF-AS: a cached window image reaches the overview scaled down to the
/// thumbnail density of the window's frame, never at its full 2x size.
final class SnapshotDownscaleTests: XCTestCase {
    private func image(width: Int, height: Int, draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    func testARetinaImageIsScaledToThreeQuartersOfAPixelPerPoint() throws {
        let full = image(width: 1600, height: 1200)
        let scaled = try XCTUnwrap(snapshotDownscaled(full, pointSize: CGSize(width: 800, height: 600), pixelsPerPoint: 0.75))
        XCTAssertEqual(scaled.width, 600)
        XCTAssertEqual(scaled.height, 450)
    }

    /// The frame may differ from the image's by the cache tolerance: the
    /// image keeps its own aspect and fits the target.
    func testTheImageKeepsItsAspectWithinTheTarget() throws {
        let full = image(width: 1600, height: 1200)
        let scaled = try XCTUnwrap(snapshotDownscaled(full, pointSize: CGSize(width: 801, height: 599), pixelsPerPoint: 0.75))
        XCTAssertEqual(scaled.width, 599)
        XCTAssertEqual(scaled.height, 449)
    }

    /// Already at or below the thumbnail density: handed on as is, never
    /// scaled up or copied.
    func testAnImageAtOrBelowTheTargetIsReturnedUnchanged() throws {
        let small = image(width: 600, height: 450)
        let same = try XCTUnwrap(snapshotDownscaled(small, pointSize: CGSize(width: 800, height: 600), pixelsPerPoint: 0.75))
        XCTAssertTrue(same === small)
        let smaller = image(width: 400, height: 300)
        let kept = try XCTUnwrap(snapshotDownscaled(smaller, pointSize: CGSize(width: 800, height: 600), pixelsPerPoint: 0.75))
        XCTAssertTrue(kept === smaller)
    }

    func testATinyFrameStillGivesOnePixel() throws {
        let full = image(width: 40, height: 20)
        let scaled = try XCTUnwrap(snapshotDownscaled(full, pointSize: CGSize(width: 0.5, height: 0.5), pixelsPerPoint: 0.75))
        XCTAssertEqual(scaled.width, 1)
        XCTAssertEqual(scaled.height, 1)
    }

    func testTheScaledImageKeepsTheContent() throws {
        let split = image(width: 1600, height: 1200) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 800, y: 0, width: 800, height: 1200))
        }
        let scaled = try XCTUnwrap(snapshotDownscaled(split, pointSize: CGSize(width: 800, height: 600), pixelsPerPoint: 0.75))
        XCTAssertFalse(snapshotLooksBlank(samples: snapshotSamples(of: scaled)))
    }
}
