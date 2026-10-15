import CoreGraphics
import XCTest
@testable import GioCore

final class FlightLayerModelTests: XCTestCase {
    private func id(_ n: UInt64) -> WindowID { WindowID(pid: 10, elementID: n) }
    private let spring = SpringParameters.niri
    private let from = CGRect(x: 0, y: 100, width: 800, height: 900)
    private let to = CGRect(x: -820, y: 100, width: 800, height: 900)

    private func drawn(_ track: FlightTrack, at elapsed: TimeInterval) -> CGRect {
        let geometry = track.state(at: elapsed, spring: spring).geometry
        let size = geometry.bounds.size
        return CGRect(
            x: geometry.position.x - size.width / 2, y: geometry.position.y - size.height / 2,
            width: size.width, height: size.height
        )
    }

    private func track(from: CGRect, to: CGRect, velocity: CGPoint = .zero) -> FlightTrack {
        FlightTrack(
            start: overlayLayerGeometry(frame: from, in: .zero, flipped: false),
            end: overlayLayerGeometry(frame: to, in: .zero, flipped: false),
            velocity: overlayLayerVelocity(origin: velocity, flipped: false)
        )
    }

    private func assertFrame(
        _ actual: CGRect?, _ expected: CGRect, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("no frame \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-6, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-6, message, file: file, line: line)
    }

    func testPrimedLayersAreDrawnAtTheirStartAndFlyingOnesFollowTheirSpring() {
        var model = FlightLayerModel(spring: spring)
        model.add(id(1), from: from, to: to, velocity: CGPoint(x: -2400, y: 0), at: 10)
        assertFrame(model.frames(at: 10.2)[id(1)], from)
        model.fly(at: 10.3)
        let expected = drawn(track(from: from, to: to, velocity: CGPoint(x: -2400, y: 0)), at: 0.1)
        assertFrame(model.frames(at: 10.4)[id(1)], expected)
        XCTAssertLessThan(expected.minX, from.minX - 100, "mid-air, well away from both ends")
        XCTAssertGreaterThan(expected.minX, to.minX)
        assertFrame(model.frames(at: 20)[id(1)], to)
    }

    func testARetargetMidAirContinuesFromWhereTheLayerIs() {
        var model = FlightLayerModel(spring: spring)
        model.add(id(1), from: from, to: to, velocity: .zero, at: 0)
        model.fly(at: 0)
        let before = model.frames(at: 0.08)[id(1)]
        let back = from
        model.retarget([id(1): back], velocities: [id(1): CGPoint(x: 5000, y: 0)], at: 0.08)
        assertFrame(model.frames(at: 0.08)[id(1)], before ?? .null)
        let carried = FlightTrack(
            start: overlayLayerGeometry(frame: from, in: .zero, flipped: false),
            end: overlayLayerGeometry(frame: to, in: .zero, flipped: false)
        ).retargeted(to: overlayLayerGeometry(frame: back, in: .zero, flipped: false), at: 0.08, spring: spring)
        assertFrame(model.frames(at: 0.13)[id(1)], drawn(carried, at: 0.05))
    }

    func testAHeldLayerTakesTrackedFramesAndAnExplicitVelocityWhenReleased() {
        var model = FlightLayerModel(spring: spring)
        model.add(id(1), from: from, to: from, velocity: .zero, at: 0)
        let tracked = from.offsetBy(dx: -300, dy: 0)
        model.track([id(1): tracked])
        assertFrame(model.frames(at: 1)[id(1)], tracked)
        model.retarget([id(1): to], velocities: [id(1): CGPoint(x: -2400, y: 0)], at: 1)
        assertFrame(model.frames(at: 1.5)[id(1)], tracked, "not flying before the release pass")
        model.fly(at: 2)
        assertFrame(model.frames(at: 2.05)[id(1)], drawn(track(from: tracked, to: to, velocity: CGPoint(x: -2400, y: 0)), at: 0.05))
    }

    func testLayersAddedWhileOthersFlyStartAtOnce() {
        var model = FlightLayerModel(spring: spring)
        model.add(id(1), from: from, to: to, velocity: .zero, at: 0)
        model.fly(at: 0)
        let entering = CGRect(x: 1600, y: 100, width: 800, height: 900)
        model.add(id(2), from: entering, to: entering.offsetBy(dx: -820, dy: 0), velocity: .zero, at: 0.1)
        assertFrame(
            model.frames(at: 0.15)[id(2)],
            drawn(track(from: entering, to: entering.offsetBy(dx: -820, dy: 0)), at: 0.05)
        )
        model.track([id(1): from])
        assertFrame(model.frames(at: 0.15)[id(1)], drawn(track(from: from, to: to), at: 0.15), "a flying layer ignores tracking")
        model.removeAll()
        XCTAssertTrue(model.frames(at: 0.2).isEmpty)
    }
}
