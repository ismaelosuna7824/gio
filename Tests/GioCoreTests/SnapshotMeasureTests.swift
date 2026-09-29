import CoreGraphics
import XCTest
@testable import GioCore

/// SM-02b: pure pieces of the capture latency measurement and the
/// shareable-content prefetch trigger.
final class SnapshotMeasureTests: XCTestCase {
    private func id(_ n: Int, pid: pid_t = 100) -> WindowID { WindowID(pid: pid, elementID: UInt64(n)) }
    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: percentiles

    func testPercentileUsesNearestRank() {
        let values: [Double] = [50, 10, 40, 20, 30]
        XCTAssertEqual(snapshotPercentile(values, 0.5), 30)
        XCTAssertEqual(snapshotPercentile(values, 0.9), 50)
        XCTAssertEqual(snapshotPercentile(values, 1.0), 50)
        XCTAssertEqual(snapshotPercentile([7], 0.5), 7)
        XCTAssertEqual(snapshotPercentile([], 0.9), 0)
    }

    // MARK: breakdown

    func testMeasurementAggregatesWindowTimings() {
        let m = SnapshotMeasurement(
            fetchMilliseconds: 31.4, fetchCached: false, windows: 9,
            windowMilliseconds: [10, 20, 30, 40, 100], backdropMilliseconds: 55.2,
            totalMilliseconds: 210.6, unmatchedReasons: [.noCGEntryForPid: 1, .noSCWindow: 2]
        )
        XCTAssertEqual(m.captured, 5)
        XCTAssertEqual(m.p50, 30)
        XCTAssertEqual(m.p90, 100)
        XCTAssertEqual(m.max, 100)
        XCTAssertEqual(m.unmatched, 3)
        XCTAssertEqual(
            m.logLine,
            "snapshot measure fetch=31ms cached=false windows=9 captured=5 p50=30ms p90=100ms max=100ms "
                + "backdrop=55ms total=211ms unmatched=3 reasons=no-cg-entry-for-pid:1,no-scwindow-for-cgwindowid:2"
        )
    }

    func testMeasurementWithoutWindowsOrBackdropIsStable() {
        let m = SnapshotMeasurement(
            fetchMilliseconds: 0, fetchCached: true, windows: 0, windowMilliseconds: [],
            backdropMilliseconds: nil, totalMilliseconds: 1, unmatchedReasons: [:]
        )
        XCTAssertEqual(
            m.logLine,
            "snapshot measure fetch=0ms cached=true windows=0 captured=0 p50=0ms p90=0ms max=0ms "
                + "backdrop=n/a total=1ms unmatched=0 reasons=none"
        )
        XCTAssertEqual(m.report.split(separator: "\n").count, 6)
    }

    // MARK: unmatched reasons

    func testClassifiesUnmatchedReasons() {
        let other = SnapshotCandidate(windowID: 5, pid: 200, frame: frame)
        let bigger = SnapshotCandidate(windowID: 6, pid: 100, frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let candidates = [other, bigger]
        XCTAssertEqual(
            classifySnapshotMiss(pid: 300, match: .missing, candidates: candidates, sckWindowIDs: [5, 6]),
            .noCGEntryForPid
        )
        XCTAssertEqual(
            classifySnapshotMiss(pid: 100, match: .missing, candidates: candidates, sckWindowIDs: [5, 6]),
            .noSizeMatch
        )
        XCTAssertEqual(
            classifySnapshotMiss(pid: 100, match: .ambiguous, candidates: candidates, sckWindowIDs: [5, 6]),
            .ambiguousSameSize
        )
        XCTAssertEqual(
            classifySnapshotMiss(pid: 100, match: .matched(6), candidates: candidates, sckWindowIDs: [5]),
            .noSCWindow
        )
        XCTAssertNil(
            classifySnapshotMiss(pid: 100, match: .matched(6), candidates: candidates, sckWindowIDs: [5, 6])
        )
    }

    // MARK: prefetch trigger

    func testPrefetchTriggersOnFirstUseAndSetChangeOnly() {
        let a: Set = [id(1), id(2)]
        XCTAssertTrue(shouldPrefetchShareableContent(managed: a, lastPrefetched: nil, permissionGranted: true, inFlight: false))
        XCTAssertFalse(shouldPrefetchShareableContent(managed: a, lastPrefetched: a, permissionGranted: true, inFlight: false))
        XCTAssertTrue(shouldPrefetchShareableContent(managed: a.union([id(3)]), lastPrefetched: a, permissionGranted: true, inFlight: false))
        XCTAssertTrue(shouldPrefetchShareableContent(managed: [id(1)], lastPrefetched: a, permissionGranted: true, inFlight: false))
    }

    func testPrefetchNeverWithoutPermissionOrWhileInFlight() {
        let a: Set = [id(1)]
        XCTAssertFalse(shouldPrefetchShareableContent(managed: a, lastPrefetched: nil, permissionGranted: false, inFlight: false))
        XCTAssertFalse(shouldPrefetchShareableContent(managed: a, lastPrefetched: nil, permissionGranted: true, inFlight: true))
    }
}
