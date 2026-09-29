import CoreGraphics
import XCTest
@testable import GioCore

/// SM-02: the pure decisions behind the ScreenCaptureKit capture module.
final class SnapshotPlanningTests: XCTestCase {
    private func id(_ n: Int, pid: pid_t = 100) -> WindowID { WindowID(pid: pid, elementID: UInt64(n)) }
    private func candidate(_ window: UInt32, pid: pid_t = 100, _ frame: CGRect) -> SnapshotCandidate {
        SnapshotCandidate(windowID: window, pid: pid, frame: frame)
    }
    private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let b = CGRect(x: 800, y: 0, width: 800, height: 600)

    // MARK: coordinates

    func testSCKFrameIsTopLeftGlobalAndFlipsToCocoa() {
        // SCWindow.frame: global, origin top-left of the primary display.
        let sck = CGRect(x: 100, y: 50, width: 400, height: 300)
        let cocoa = snapshotCocoaFrame(fromSCK: sck, primaryDisplayHeight: 1000)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 650, width: 400, height: 300))
        XCTAssertEqual(snapshotCocoaFrame(fromSCK: cocoa, primaryDisplayHeight: 1000), sck)
    }

    func testPixelSizeScalesAndRoundsUp() {
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800, height: 600), scale: 2).width, 1600)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800.5, height: 600.2), scale: 2).width, 1601)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 800.5, height: 600.2), scale: 2).height, 1201)
        XCTAssertEqual(snapshotPixelSize(points: CGSize(width: 0, height: 10), scale: 2).width, 1)
    }

    func testBackingScaleUsesTheDisplayWithMostOverlap() {
        let displays = [
            SnapshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
            SnapshotDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), scale: 1),
        ]
        XCTAssertEqual(backingScale(for: CGRect(x: 900, y: 0, width: 400, height: 300), displays: displays), 1)
        XCTAssertEqual(backingScale(for: CGRect(x: 100, y: 0, width: 400, height: 300), displays: displays), 2)
        XCTAssertEqual(backingScale(for: CGRect(x: 5000, y: 0, width: 400, height: 300), displays: displays), 2)
        XCTAssertEqual(backingScale(for: a, displays: []), 2)
    }

    // MARK: matching

    func testExactFrameMatchesFirst() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a, id(2): b],
            candidates: [candidate(11, a), candidate(12, b)]
        )
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .matched(12))
    }

    func testSamePidSameSizeExactClaimsBeforeUniqueSize() {
        // Two windows of one app with the same size: each takes its own entry.
        let result = matchSnapshotCandidates(
            managed: [id(1): a, id(2): b],
            candidates: [candidate(12, b), candidate(11, a)]
        )
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .matched(12))
    }

    func testUniqueSameSizeMatchesWhenPositionDiffers() {
        let moved = a.offsetBy(dx: 300, dy: 40)
        let result = matchSnapshotCandidates(managed: [id(1): a], candidates: [candidate(11, moved)])
        XCTAssertEqual(result[id(1)], .matched(11))
    }

    func testSeveralSameSizeCandidatesAreAmbiguous() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a],
            candidates: [candidate(11, a.offsetBy(dx: 100, dy: 0)), candidate(12, a.offsetBy(dx: 200, dy: 0))]
        )
        XCTAssertEqual(result[id(1)], .ambiguous)
    }

    func testOtherPidsAndOtherSizesAreMissing() {
        let result = matchSnapshotCandidates(
            managed: [id(1): a],
            candidates: [candidate(11, pid: 200, a), candidate(12, CGRect(x: 0, y: 0, width: 300, height: 300))]
        )
        XCTAssertEqual(result[id(1)], .missing)
    }

    func testEachCandidateIsClaimedOnce() {
        let result = matchSnapshotCandidates(managed: [id(1): a, id(2): a], candidates: [candidate(11, a)])
        XCTAssertEqual(result[id(1)], .matched(11))
        XCTAssertEqual(result[id(2)], .missing)
    }

    // MARK: exclusions and backdrops

    func testExclusionsHoldAnimatedAndGioOwnedWindowsOnce() {
        let candidates = [
            candidate(11, pid: 100, a), candidate(12, pid: 100, b),
            candidate(90, pid: 999, a), candidate(91, pid: 999, b), candidate(13, pid: 300, a),
        ]
        let result = snapshotExclusions(candidates: candidates, animated: [12, 11, 12], ownPid: 999)
        XCTAssertEqual(result, [11, 12, 90, 91])
    }

    func testBackdropsOnlyForDisplaysTheWindowsTouch() {
        let displays = [
            SnapshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
            SnapshotDisplay(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), scale: 2),
        ]
        XCTAssertEqual(
            displaysNeedingBackdrop(windowFrames: [CGRect(x: 100, y: 0, width: 500, height: 500)], displays: displays),
            [1]
        )
        XCTAssertEqual(
            displaysNeedingBackdrop(windowFrames: [CGRect(x: 900, y: 0, width: 300, height: 500)], displays: displays),
            [1, 2]
        )
        XCTAssertEqual(displaysNeedingBackdrop(windowFrames: [], displays: displays), [])
    }

    // MARK: budget accounting

    func testSummaryAccountsMissesByReason() {
        let requested = [id(1), id(2), id(3), id(4), id(5)]
        let matches: [WindowID: SnapshotMatch] = [
            id(1): .matched(11), id(2): .matched(12), id(3): .matched(13), id(4): .ambiguous, id(5): .missing,
        ]
        let summary = makeSnapshotSummary(
            requested: requested, matches: matches, captured: [id(1)], failed: [id(2)],
            backdropsRequested: 1, backdropsCaptured: 1, elapsedMilliseconds: 41.6
        )
        XCTAssertEqual(summary.windows, 5)
        XCTAssertEqual(summary.captured, 1)
        XCTAssertEqual(summary.misses[id(2)], .failed)
        XCTAssertEqual(summary.misses[id(3)], .overBudget)
        XCTAssertEqual(summary.misses[id(4)], .ambiguous)
        XCTAssertEqual(summary.misses[id(5)], .unmatched)
        XCTAssertNil(summary.misses[id(1)])
        XCTAssertEqual(
            summary.logLine, "snapshot capture windows=5 captured=1 backdrop=true ms=42 misses=4"
        )
    }

    func testBackdropFlagNeedsEveryRequestedBackdrop() {
        func line(_ requested: Int, _ captured: Int) -> String {
            makeSnapshotSummary(
                requested: [], matches: [:], captured: [], failed: [],
                backdropsRequested: requested, backdropsCaptured: captured, elapsedMilliseconds: 3
            ).logLine
        }
        XCTAssertTrue(line(2, 2).contains("backdrop=true"))
        XCTAssertTrue(line(2, 1).contains("backdrop=false"))
        XCTAssertTrue(line(0, 0).contains("backdrop=false"))
    }

    func testDefaultBudgetIs45Milliseconds() {
        XCTAssertEqual(SnapshotBudget.defaultMilliseconds, 45)
    }
}
