import XCTest
@testable import GioCore

/// FI-03: motion animates the origin only. A dimension that shrinks is
/// applied in the first frame, one that grows waits for the final exact
/// pass, so the old composition never overlaps the new one mid-flight.
final class MotionOverlapTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private func animation(
        from: CGRect, to: CGRect, easing: AnimationEasing = .linear
    ) -> WindowAnimation {
        WindowAnimation(id: id(1), from: from, to: to, duration: 1, easing: easing)
    }

    // MARK: Size timing

    func testShrinkingDimensionsApplyFromTheFirstFrame() {
        let flight = animation(
            from: CGRect(x: 0, y: 0, width: 500, height: 400),
            to: CGRect(x: 200, y: 0, width: 300, height: 200)
        )
        for elapsed in [0.0, 0.25, 0.75, 1.0] {
            XCTAssertEqual(flight.motionFrame(at: elapsed).size, CGSize(width: 300, height: 200))
        }
        XCTAssertEqual(flight.motionFrame(at: 0.5).origin.x, 100, accuracy: 1e-9)
    }

    func testGrowingDimensionsKeepOldSizeEvenAtCompletion() {
        let flight = animation(
            from: CGRect(x: 0, y: 0, width: 300, height: 200),
            to: CGRect(x: 200, y: 0, width: 500, height: 400)
        )
        for elapsed in [0.0, 0.5, 1.0, 5.0] {
            XCTAssertEqual(flight.motionFrame(at: elapsed).size, CGSize(width: 300, height: 200))
        }
        XCTAssertEqual(flight.motionFrame(at: 1.0).origin, CGPoint(x: 200, y: 0))
    }

    func testMixedDimensionsShrinkNowAndGrowLater() {
        let flight = animation(
            from: CGRect(x: 0, y: 0, width: 300, height: 400),
            to: CGRect(x: 0, y: 0, width: 500, height: 200)
        )
        XCTAssertEqual(flight.motionFrame(at: 0).size, CGSize(width: 300, height: 200))
        XCTAssertEqual(flight.motionFrame(at: 1).size, CGSize(width: 300, height: 200))
    }

    func testOriginFollowsTheEasingLikeTheFullFrame() {
        let flight = animation(
            from: CGRect(x: 0, y: 10, width: 300, height: 200),
            to: CGRect(x: 100, y: 50, width: 400, height: 100), easing: .easeOut
        )
        for elapsed in [0.0, 0.3, 0.6, 1.0] {
            XCTAssertEqual(flight.motionFrame(at: elapsed).origin, flight.frame(at: elapsed).origin)
        }
    }

    // MARK: Player: position-only frames

    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 0
        var reading: ReflowClock { { [self] in now } }
    }

    private final class RecordingSink: MotionFrameSink {
        var writes: [MotionWrite] = []
        func submitMotion(pid: pid_t, writes: [MotionWrite]) -> Bool {
            self.writes += writes
            return true
        }
        func waitForMotionIdle(timeout: TimeInterval) {}
        func takeMotionStats() -> [pid_t: MotionWriteStats] { [:] }
    }

    func testAfterTheFirstFrameEveryWriteIsPositionOnly() {
        let clock = FakeClock(), sink = RecordingSink()
        let player = MotionPlayer(sink: sink, clock: clock.reading)
        player.start([
            WindowAnimation(
                id: id(1), from: CGRect(x: 0, y: 0, width: 500, height: 400),
                to: CGRect(x: 200, y: 0, width: 300, height: 400), duration: 1, easing: .linear
            ),
            WindowAnimation(
                id: id(2), from: CGRect(x: 600, y: 0, width: 300, height: 400),
                to: CGRect(x: 400, y: 0, width: 500, height: 400), duration: 1, easing: .linear
            ),
        ])
        for step in 0...10 {
            clock.now = Double(step) / 10
            _ = player.tick()
        }
        let shrinking = sink.writes.filter { $0.id == id(1) }
        XCTAssertEqual(shrinking.first?.to.size, CGSize(width: 300, height: 400))
        XCTAssertNotEqual(shrinking.first?.from.size, shrinking.first?.to.size)
        for write in shrinking.dropFirst() {
            XCTAssertEqual(write.from.size, write.to.size)
        }
        for write in sink.writes.filter({ $0.id == id(2) }) {
            XCTAssertEqual(write.from.size, CGSize(width: 300, height: 400))
            XCTAssertEqual(write.to.size, CGSize(width: 300, height: 400))
        }
    }

    // MARK: No overlap mid-flight

    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func layout(_ columns: [Column]) throws -> [WindowID: CGRect] {
        try ScrollableLayoutEngine().calculate(
            workspace: Workspace(id: WorkspaceID(1), columns: columns), viewport: viewport
        ).frames
    }

    private func column(
        _ raw: UInt64, width: CGFloat, _ windows: [WindowID], weights: [WindowID: CGFloat] = [:]
    ) -> Column {
        var column = Column(id: ColumnID(raw), width: width, windows: windows, focusedWindowIndex: 0)
        column.heightWeights = weights
        return column
    }

    private func overlaps(_ frames: [WindowID: CGRect]) -> [(WindowID, WindowID)] {
        let ids = frames.keys.sorted()
        var found: [(WindowID, WindowID)] = []
        for (index, a) in ids.enumerated() {
            for b in ids[(index + 1)...] {
                let shared = frames[a]!.intersection(frames[b]!)
                if !shared.isNull, shared.width > 0.001, shared.height > 0.001 {
                    found.append((a, b))
                }
            }
        }
        return found
    }

    /// Plays `before` -> `after` through the real planner and player,
    /// applying every accepted write to a physical frame model, and returns
    /// the model at each requested fraction plus the frames after the final
    /// exact pass.
    private func play(
        before: [WindowID: CGRect], after: [WindowID: CGRect], easing: AnimationEasing
    ) -> (samples: [Double: [WindowID: CGRect]], settled: [WindowID: CGRect]) {
        let clock = FakeClock(), sink = RecordingSink()
        let player = MotionPlayer(sink: sink, clock: clock.reading)
        player.start(planMotion(
            current: before, visible: after, parked: [:], viewport: viewport, duration: 1, easing: easing
        ))
        var physical = before
        var samples: [Double: [WindowID: CGRect]] = [:]
        for step in 0...20 {
            clock.now = Double(step) / 20
            sink.writes = []
            _ = player.tick()
            for write in sink.writes {
                physical[write.id] = write.to
            }
            let fraction = Double(step) / 20
            if [0.25, 0.5, 0.75, 1.0].contains(fraction) {
                samples[fraction] = physical
            }
        }
        // The final exact pass writes whatever the layout says.
        return (samples, physical.merging(after) { _, layout in layout })
    }

    private func assertNoOverlap(
        _ before: [WindowID: CGRect], _ after: [WindowID: CGRect],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for easing in [AnimationEasing.linear, .easeOut, .easeInOut] {
            let result = play(before: before, after: after, easing: easing)
            for (fraction, frames) in result.samples.sorted(by: { $0.key < $1.key }) {
                XCTAssertTrue(
                    overlaps(frames).isEmpty,
                    "overlap at t=\(fraction) easing=\(easing): \(frames)", file: file, line: line
                )
            }
            XCTAssertEqual(result.settled, after, file: file, line: line)
            XCTAssertTrue(overlaps(result.settled).isEmpty, file: file, line: line)
        }
    }

    func testStackedColumnHeightsChangingNeverOverlap() throws {
        let stack = [id(1), id(2)]
        let even = try layout([column(1, width: 400, stack)])
        let topSmall = try layout([column(1, width: 400, stack, weights: [id(1): 1, id(2): 3])])
        assertNoOverlap(even, topSmall)
        assertNoOverlap(topSmall, even)
        let topBig = try layout([column(1, width: 400, stack, weights: [id(1): 3, id(2): 1])])
        assertNoOverlap(topSmall, topBig)
        assertNoOverlap(topBig, topSmall)
    }

    func testAdjacentColumnWidthsChangingNeverOverlap() throws {
        let narrow = try layout([
            column(1, width: 300, [id(1)]), column(2, width: 300, [id(2)]), column(3, width: 300, [id(3)]),
        ])
        let wide = try layout([
            column(1, width: 500, [id(1)]), column(2, width: 250, [id(2)]), column(3, width: 300, [id(3)]),
        ])
        assertNoOverlap(narrow, wide)
        assertNoOverlap(wide, narrow)
    }

    func testStackAndNeighbourWidthChangeTogetherNeverOverlap() throws {
        let stack = [id(1), id(2)]
        let before = try layout([column(1, width: 300, stack), column(2, width: 300, [id(3)])])
        let after = try layout([
            column(1, width: 500, stack, weights: [id(1): 1, id(2): 2]), column(2, width: 300, [id(3)]),
        ])
        assertNoOverlap(before, after)
        assertNoOverlap(after, before)
    }
}
