import XCTest
@testable import GioCore

/// TG-01: trackpad contact frames become swipe gestures: finger count,
/// centroid, commit threshold, axis lock, an 80 ms velocity window and the
/// finger-count rules (a new count restarts recognition, an extra finger
/// cancels a scroll, lifting ends it).
final class GestureRecognizerTests: XCTestCase {
    private let settings = GestureRecognizerSettings(horizontalFingers: 3, verticalFingers: [3, 4])

    /// `count` fingers spread 0.1 apart around (x, y).
    private func frame(_ t: TimeInterval, fingers count: Int, x: Double, y: Double = 0.5) -> TouchFrame {
        TouchFrame(timestamp: t, contacts: (0..<count).map {
            TouchContact(id: Int32($0), x: x + Double($0) * 0.1 - Double(count - 1) * 0.05, y: y)
        })
    }

    private func feed(_ recognizer: inout GestureRecognizer, _ frames: [TouchFrame]) -> [TrackpadGestureEvent] {
        frames.flatMap { recognizer.feed($0) }
    }

    func testCentroidAveragesTheContacts() {
        let touches = TouchFrame(timestamp: 0, contacts: [
            TouchContact(id: 1, x: 0.2, y: 0.4), TouchContact(id: 2, x: 0.4, y: 0.6), TouchContact(id: 3, x: 0.6, y: 0.5),
        ])
        let centroid = touches.centroid
        XCTAssertEqual(centroid.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(centroid.y, 0.5, accuracy: 1e-9)
    }

    func testMovementBelowTheCommitThresholdEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5), frame(0.01, fingers: 3, x: 0.52), frame(0.02, fingers: 0, x: 0),
        ])
        XCTAssertEqual(events, [])
    }

    func testHorizontalMovementPastTheThresholdBeginsAScrollWithTheWholeTravel() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5), frame(0.01, fingers: 3, x: 0.46, y: 0.51),
        ])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .scrollBegan(fingers: 3))
        guard case .scrollChanged(let dx) = events.last else {
            return XCTFail("expected a change, got \(events)")
        }
        XCTAssertEqual(dx, -0.04, accuracy: 1e-9)
    }

    func testAxisLockIgnoresVerticalDriftOnceScrolling() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5), frame(0.01, fingers: 3, x: 0.54),
            frame(0.02, fingers: 3, x: 0.55, y: 0.8),
        ])
        XCTAssertEqual(events.count, 3)
        guard case .scrollChanged(let dx) = events.last else {
            return XCTFail("expected a horizontal change, got \(events)")
        }
        XCTAssertEqual(dx, 0.01, accuracy: 1e-9)
    }

    /// TG-08: a vertical swipe needs a deliberate stroke: it fires once, at
    /// the frame its vertical travel reaches the swipe distance, and nothing
    /// more until the fingers lift.
    func testADeliberateVerticalSwipeEmitsOnceAtTheSwipeDistance() {
        var recognizer = GestureRecognizer(settings: settings)
        let early = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.36),
            frame(0.02, fingers: 3, x: 0.5, y: 0.42),
        ])
        XCTAssertEqual(early, [], "locked vertically but short of the swipe distance")
        let events = feed(&recognizer, [
            frame(0.03, fingers: 3, x: 0.5, y: 0.46), frame(0.04, fingers: 3, x: 0.5, y: 0.7),
            frame(0.05, fingers: 3, x: 0.5, y: 0.2),
        ])
        XCTAssertEqual(swipes(events), [VerticalSwipe(fingers: 3, direction: .up)])
        if case .verticalSwipe(_, _, let distance) = events.first {
            XCTAssertEqual(distance, 0.16, accuracy: 1e-6)
        }
        let next = feed(&recognizer, [
            frame(0.06, fingers: 0, x: 0), frame(0.07, fingers: 3, x: 0.5, y: 0.6),
            frame(0.08, fingers: 3, x: 0.5, y: 0.5), frame(0.09, fingers: 3, x: 0.5, y: 0.4),
        ])
        XCTAssertEqual(swipes(next), [VerticalSwipe(fingers: 3, direction: .down)])
    }

    /// TG-08: about 3 mm of vertical drift (resting fingers, the start of a
    /// scroll) used to switch workspace.
    func testASmallVerticalDriftEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.335),
            frame(0.02, fingers: 3, x: 0.5, y: 0.34), frame(0.03, fingers: 0, x: 0),
        ])
        XCTAssertEqual(events, [])
    }

    func testADiagonalStrokeEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.52, y: 0.33),
            frame(0.02, fingers: 3, x: 0.65, y: 0.6), frame(0.03, fingers: 3, x: 0.8, y: 0.9),
        ])
        XCTAssertEqual(events, [], "|dy| below twice |dx| at the lock is not a swipe")
    }

    func testLiftingBeforeTheSwipeDistanceEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.4),
            frame(0.02, fingers: 0, x: 0), frame(0.03, fingers: 3, x: 0.5, y: 0.5),
        ])
        XCTAssertEqual(events, [])
    }

    func testAFingerChangeBeforeTheSwipeDistanceEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.4),
            frame(0.02, fingers: 4, x: 0.5, y: 0.4), frame(0.03, fingers: 4, x: 0.5, y: 0.8),
        ])
        XCTAssertEqual(events, [])
    }

    func testASwipeThatTurnsDiagonalEmitsNothing() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.38),
            frame(0.02, fingers: 3, x: 0.6, y: 0.42), frame(0.03, fingers: 3, x: 0.6, y: 0.8),
        ])
        XCTAssertEqual(events, [])
    }

    func testTheSwipeDistanceIsASetting() {
        var custom = settings
        custom.swipeDistance = 0.3
        var recognizer = GestureRecognizer(settings: custom)
        let short = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.2), frame(0.01, fingers: 3, x: 0.5, y: 0.45),
        ])
        XCTAssertEqual(short, [])
        XCTAssertEqual(GestureRecognizerSettings.defaultSwipeDistance, 0.15)
        XCTAssertEqual(GestureRecognizerSettings.verticalDominance, 2.0)
        let long = feed(&recognizer, [frame(0.02, fingers: 3, x: 0.5, y: 0.55)])
        XCTAssertEqual(swipes(long), [VerticalSwipe(fingers: 3, direction: .up)])
    }

    private struct VerticalSwipe: Equatable {
        var fingers: Int
        var direction: SwipeDirection
    }

    /// Every event as a vertical swipe (others become a sentinel so they fail).
    private func swipes(_ events: [TrackpadGestureEvent]) -> [VerticalSwipe] {
        events.map {
            guard case .verticalSwipe(let fingers, let direction, _) = $0 else {
                return VerticalSwipe(fingers: -1, direction: .up)
            }
            return VerticalSwipe(fingers: fingers, direction: direction)
        }
    }

    func testAnAxisWithoutAGestureConsumesTheTouchesUntilLift() {
        var recognizer = GestureRecognizer(settings: GestureRecognizerSettings(horizontalFingers: 3, verticalFingers: []))
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 3, x: 0.5, y: 0.4),
            frame(0.02, fingers: 3, x: 0.7, y: 0.4),
        ])
        XCTAssertEqual(events, [], "a vertical start never turns into a scroll later")
    }

    func testFingerCountsWithoutAGestureAreIgnored() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 2, x: 0.5), frame(0.01, fingers: 2, x: 0.3),
            frame(0.02, fingers: 5, x: 0.3), frame(0.03, fingers: 5, x: 0.1),
        ])
        XCTAssertEqual(events, [])
    }

    func testAFingerLandingRestartsRecognitionFromTheNewCentroid() {
        var recognizer = GestureRecognizer(settings: settings)
        // Two fingers scroll (the system's scroll), then a third lands far away.
        let events = feed(&recognizer, [
            frame(0, fingers: 2, x: 0.5), frame(0.01, fingers: 2, x: 0.3),
            frame(0.02, fingers: 3, x: 0.3), frame(0.03, fingers: 3, x: 0.31),
        ])
        XCTAssertEqual(events, [], "the jump of the centroid when a finger lands is not movement")
        let moved = feed(&recognizer, [frame(0.04, fingers: 3, x: 0.35)])
        XCTAssertEqual(moved.first, .scrollBegan(fingers: 3))
    }

    func testCountChangeBeforeCommitRestartsTracking() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5, y: 0.3), frame(0.01, fingers: 4, x: 0.5, y: 0.3),
            frame(0.02, fingers: 4, x: 0.5, y: 0.4), frame(0.03, fingers: 4, x: 0.5, y: 0.5),
        ])
        XCTAssertEqual(swipes(events), [VerticalSwipe(fingers: 4, direction: .up)])
    }

    func testAnExtraFingerCancelsAScroll() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.5), frame(0.01, fingers: 3, x: 0.45),
            frame(0.02, fingers: 4, x: 0.45), frame(0.03, fingers: 4, x: 0.2),
        ])
        XCTAssertEqual(events.last, .scrollCancelled)
        XCTAssertEqual(events.filter { $0 == .scrollCancelled }.count, 1)
        XCTAssertEqual(feed(&recognizer, [frame(0.04, fingers: 3, x: 0.1)]), [], "consumed until every finger lifts")
    }

    func testLiftingEndsTheScrollWithTheVelocityOfTheLast80Milliseconds() {
        var recognizer = GestureRecognizer(settings: settings)
        // Slow at first, then 1.0 units per second for the last 100 ms.
        var frames = [frame(0, fingers: 3, x: 0.2), frame(0.1, fingers: 3, x: 0.25)]
        for step in 1...10 {
            frames.append(frame(0.1 + Double(step) * 0.01, fingers: 3, x: 0.25 + Double(step) * 0.01))
        }
        frames.append(frame(0.2, fingers: 2, x: 0.35))
        let events = feed(&recognizer, frames)
        guard case .scrollEnded(let velocity) = events.last else {
            return XCTFail("expected an end, got \(events.suffix(2))")
        }
        XCTAssertEqual(velocity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(feed(&recognizer, [frame(0.21, fingers: 2, x: 0.6)]), [], "consumed until every finger lifts")
        XCTAssertEqual(feed(&recognizer, [frame(0.22, fingers: 0, x: 0)]), [])
    }

    func testFingersThatRestBeforeLiftingEndWithoutVelocity() {
        var recognizer = GestureRecognizer(settings: settings)
        let events = feed(&recognizer, [
            frame(0, fingers: 3, x: 0.2), frame(0.02, fingers: 3, x: 0.3), frame(0.04, fingers: 3, x: 0.4),
            frame(0.2, fingers: 3, x: 0.4), frame(0.3, fingers: 0, x: 0),
        ])
        XCTAssertEqual(events.last, .scrollEnded(velocity: 0))
    }

    func testVelocityTrackerKeepsOnlyItsWindow() {
        var tracker = SwipeVelocityTracker()
        tracker.push(position: 0, at: 0)
        tracker.push(position: 10, at: 0.5)
        tracker.push(position: 10.4, at: 0.54)
        tracker.push(position: 10.8, at: 0.58)
        XCTAssertEqual(tracker.velocity(), 10, accuracy: 1e-9, "only the samples within 80 ms of the last count")
        XCTAssertEqual(SwipeVelocityTracker.window, 0.08)
        tracker.reset()
        XCTAssertEqual(tracker.velocity(), 0)
    }

    func testSettingsChangesApplyToTheNextGesture() {
        var recognizer = GestureRecognizer(settings: settings)
        recognizer.settings = GestureRecognizerSettings(horizontalFingers: 4, verticalFingers: [])
        let events = feed(&recognizer, [frame(0, fingers: 4, x: 0.5), frame(0.01, fingers: 4, x: 0.6)])
        XCTAssertEqual(events.first, .scrollBegan(fingers: 4))
    }

    /// The touch callback runs at the trackpad's rate whenever a finger
    /// rests on it (pointer moves too); only frames that matter cross to the
    /// session queue.
    func testFrameGateAdmitsGestureCountsAndTheFrameThatEndsThem() {
        var gate = TouchFrameGate(minimumFingers: 3)
        XCTAssertFalse(gate.admits(1), "pointer movement stays on the callback thread")
        XCTAssertFalse(gate.admits(2))
        XCTAssertTrue(gate.admits(3))
        XCTAssertTrue(gate.admits(3))
        XCTAssertTrue(gate.admits(2), "the drop below the minimum is delivered once")
        XCTAssertFalse(gate.admits(1))
        XCTAssertFalse(gate.admits(0))
        gate.minimumFingers = 0
        XCTAssertFalse(gate.admits(4), "no gesture enabled: nothing crosses")
    }
}
