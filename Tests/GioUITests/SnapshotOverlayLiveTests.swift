import AppKit
import CoreVideo
import GioCore
import IOSurface
import QuartzCore
import XCTest
@testable import GioUI

@MainActor
final class SnapshotOverlayLiveTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let window = WindowID(pid: 4242, elementID: 7)

    private func image(_ size: CGSize) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    private func surface() -> IOSurface {
        IOSurface(properties: [
            .width: 8, .height: 6, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ])!
    }

    private func item(
        _ id: WindowID, from: CGRect, to: CGRect, imageSize: CGSize? = nil, seeThrough: Bool = false
    ) -> SnapshotOverlayItem {
        let size = imageSize ?? from.size
        return SnapshotOverlayItem(
            id: id, image: SnapshotFace(image: image(size), size: size, fill: nil), target: nil, from: from, to: to,
            seeThrough: seeThrough
        )
    }

    private func overlay(with items: [SnapshotOverlayItem]) -> SnapshotOverlay {
        let overlay = SnapshotOverlay(displayFrame: display, spring: .niri)
        _ = overlay.retarget(
            targets: [:], images: [:], velocities: [:], adding: items, holes: OverlayHoles(), decorations: .none,
            now: CACurrentMediaTime()
        )
        return overlay
    }

    func testALiveFrameDrawsOnTopOfTheImageOfAMovingLayer() throws {
        let moved = frame.offsetBy(dx: 300, dy: 0)
        let overlay = overlay(with: [item(window, from: frame, to: moved)])
        let frameSurface = surface()

        XCTAssertTrue(overlay.showLive(window, surface: frameSurface, size: frame.size))

        let live = try XCTUnwrap(overlay.liveLayers[window])
        let clip = try XCTUnwrap(live.superlayer)
        XCTAssertTrue(live.contents as AnyObject === frameSurface)
        XCTAssertNotNil(clip.contents)
        XCTAssertTrue(clip.masksToBounds)
        XCTAssertEqual(live.frame, clip.bounds)
        XCTAssertEqual(live.contentsGravity, .resize)
        XCTAssertEqual(live.contentsScale, clip.contentsScale)
        XCTAssertEqual(live.opacity, 1)
        XCTAssertNil(live.animationKeys())
    }

    func testALiveFrameDrawsAboveEveryFaceOfAResizingLayer() throws {
        let grown = CGRect(x: 100, y: 100, width: 600, height: 400)
        let overlay = overlay(with: [item(window, from: frame, to: grown)])

        XCTAssertTrue(overlay.showLive(window, surface: surface(), size: grown.size))

        let live = try XCTUnwrap(overlay.liveLayers[window])
        let clip = try XCTUnwrap(live.superlayer)
        let faces = (clip.sublayers ?? []).filter { $0 !== live }
        XCTAssertFalse(faces.isEmpty)
        XCTAssertTrue(faces.allSatisfy { $0.zPosition < live.zPosition })
        XCTAssertEqual(live.frame, clip.bounds)
    }

    func testTheLiveLayerFollowsTheClipBoundsTrackOfAFlyingResize() throws {
        let grown = CGRect(x: 100, y: 100, width: 600, height: 400)
        let overlay = overlay(with: [item(window, from: frame, to: grown)])
        _ = overlay.fly(now: CACurrentMediaTime())

        XCTAssertTrue(overlay.showLive(window, surface: surface(), size: grown.size))

        let live = try XCTUnwrap(overlay.liveLayers[window])
        let clip = try XCTUnwrap(live.superlayer)
        let clipTrack = try XCTUnwrap(clip.animation(forKey: "gio.bounds") as? CAKeyframeAnimation)
        let liveTrack = try XCTUnwrap(live.animation(forKey: "gio.bounds") as? CAKeyframeAnimation)
        XCTAssertEqual(liveTrack.values as? [NSValue], clipTrack.values as? [NSValue])
        XCTAssertEqual(liveTrack.beginTime, clipTrack.beginTime)
        XCTAssertEqual(live.bounds, clip.bounds)
        XCTAssertEqual(live.anchorPoint, CGPoint(x: 0, y: 1))
        XCTAssertEqual(live.position, .zero)
    }

    func testALiveLayerShownWhilePrimedTakesTheTrackWhenTheLayerFlies() throws {
        let grown = CGRect(x: 100, y: 100, width: 600, height: 400)
        let overlay = overlay(with: [item(window, from: frame, to: grown)])
        XCTAssertTrue(overlay.showLive(window, surface: surface(), size: frame.size))
        let live = try XCTUnwrap(overlay.liveLayers[window])
        XCTAssertNil(live.animation(forKey: "gio.bounds"))

        _ = overlay.fly(now: CACurrentMediaTime())

        let clip = try XCTUnwrap(live.superlayer)
        let clipTrack = try XCTUnwrap(clip.animation(forKey: "gio.bounds") as? CAKeyframeAnimation)
        let liveTrack = try XCTUnwrap(live.animation(forKey: "gio.bounds") as? CAKeyframeAnimation)
        XCTAssertEqual(liveTrack.values as? [NSValue], clipTrack.values as? [NSValue])
        XCTAssertEqual(live.bounds, clip.bounds)
    }

    func testAFrameForAnUnknownWindowIsDropped() {
        let overlay = overlay(with: [item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0))])

        XCTAssertFalse(overlay.showLive(WindowID(pid: 4242, elementID: 8), surface: surface(), size: frame.size))
        XCTAssertTrue(overlay.liveLayers.isEmpty)
    }

    func testAFrameForASeeThroughLayerIsDropped() {
        let overlay = overlay(with: [item(window, from: frame, to: frame, seeThrough: true)])

        XCTAssertFalse(overlay.showLive(window, surface: surface(), size: frame.size))
        XCTAssertTrue(overlay.liveLayers.isEmpty)
    }

    func testAnEmptyFrameIsDropped() {
        let overlay = overlay(with: [item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0))])

        XCTAssertFalse(overlay.showLive(window, surface: surface(), size: .zero))
        XCTAssertTrue(overlay.liveLayers.isEmpty)
    }

    func testASecondFrameReplacesTheContentsWithoutAddingLayers() throws {
        let overlay = overlay(with: [item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0))])
        overlay.showLive(window, surface: surface(), size: frame.size)
        let live = try XCTUnwrap(overlay.liveLayers[window])
        let clip = try XCTUnwrap(live.superlayer)
        let count = clip.sublayers?.count
        let next = surface()

        overlay.showLive(window, surface: next, size: frame.size)

        XCTAssertTrue(overlay.liveLayers[window] === live)
        XCTAssertTrue(live.contents as AnyObject === next)
        XCTAssertEqual(clip.sublayers?.count, count)
        XCTAssertNil(live.animationKeys())
    }

    func testClearLiveRemovesEveryLiveLayerAndKeepsTheImages() throws {
        let other = WindowID(pid: 4243, elementID: 1)
        let overlay = overlay(with: [
            item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0)),
            item(other, from: frame.offsetBy(dx: 0, dy: 400), to: frame.offsetBy(dx: 300, dy: 400)),
        ])
        overlay.showLive(window, surface: surface(), size: frame.size)
        overlay.showLive(other, surface: surface(), size: frame.size)
        let live = try XCTUnwrap(overlay.liveLayers[window])
        let clip = try XCTUnwrap(live.superlayer)

        overlay.clearLive()

        XCTAssertTrue(overlay.liveLayers.isEmpty)
        XCTAssertNil(live.superlayer)
        XCTAssertNotNil(clip.contents)
        XCTAssertEqual(overlay.ids, [window, other])
    }

    func testClearLiveOfOneWindowKeepsTheOtherWindowsLive() throws {
        let other = WindowID(pid: 4243, elementID: 1)
        let overlay = overlay(with: [
            item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0)),
            item(other, from: frame.offsetBy(dx: 0, dy: 400), to: frame.offsetBy(dx: 300, dy: 400)),
        ])
        overlay.showLive(window, surface: surface(), size: frame.size)
        overlay.showLive(other, surface: surface(), size: frame.size)

        overlay.clearLive([window])

        XCTAssertNil(overlay.liveLayers[window])
        XCTAssertNotNil(overlay.liveLayers[other])
        XCTAssertEqual(overlay.ids, [window, other])
    }

    func testTheOverlaysEndDropsTheLiveLayersWithTheirWindows() throws {
        let overlay = overlay(with: [item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0))])
        overlay.showLive(window, surface: surface(), size: frame.size)
        let clip = try XCTUnwrap(overlay.liveLayers[window]?.superlayer)

        overlay.end()

        XCTAssertTrue(overlay.liveLayers.isEmpty)
        XCTAssertNil(clip.superlayer)
        XCTAssertFalse(overlay.showLive(window, surface: surface(), size: frame.size))
    }

    func testANewLayerForTheSameWindowStartsWithoutLiveContent() {
        let overlay = overlay(with: [item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0))])
        overlay.showLive(window, surface: surface(), size: frame.size)

        _ = overlay.retarget(
            targets: [:], images: [:], velocities: [:],
            adding: [item(window, from: frame, to: frame.offsetBy(dx: -300, dy: 0))], holes: OverlayHoles(),
            decorations: .none, now: CACurrentMediaTime()
        )

        XCTAssertTrue(overlay.liveLayers.isEmpty)
    }

    func testTheHandOffFadeCarriesTheLiveContentWithTheLayer() throws {
        let other = WindowID(pid: 4243, elementID: 1)
        let overlay = overlay(with: [
            item(window, from: frame, to: frame.offsetBy(dx: 300, dy: 0)),
            item(other, from: frame.offsetBy(dx: 0, dy: 400), to: frame.offsetBy(dx: 300, dy: 400)),
        ])
        overlay.showLive(window, surface: surface(), size: frame.size)
        overlay.showLive(other, surface: surface(), size: frame.size)
        let gone = try XCTUnwrap(overlay.liveLayers[other]?.superlayer)

        XCTAssertTrue(overlay.fadeOut(keeping: [window], duration: 0.12, now: CACurrentMediaTime()))

        let clip = try XCTUnwrap(overlay.liveLayers[window]?.superlayer)
        XCTAssertNotNil(clip.animation(forKey: "gio.fade"))
        XCTAssertEqual(Set(overlay.liveLayers.keys), [window])
        XCTAssertNil(gone.superlayer)
    }

    func testTheControllerDropsAFrameWithoutAFlight() {
        let controller = SnapshotOverlayController()

        controller.showLive(window, surface: surface(), size: frame.size)
        controller.clearLive()

        XCTAssertFalse(controller.isActive)
    }
}
