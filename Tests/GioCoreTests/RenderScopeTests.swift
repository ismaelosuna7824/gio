import XCTest
@testable import GioCore

/// PA-04: the render check looks only at visible windows written or animated
/// in the settle, and reuses the frames the settle already read.
final class RenderScopeTests: XCTestCase {
    private func id(_ element: UInt64) -> WindowID {
        WindowID(pid: 10, elementID: element)
    }

    private let a = CGRect(x: 0, y: 0, width: 500, height: 900)
    private let b = CGRect(x: 500, y: 0, width: 500, height: 900)

    func testCandidatesAreLimitedToVisibleTargetsWithASettledFrame() {
        let targets = renderCheckFrames(
            candidates: [id(1), id(2), id(3), id(4)],
            visible: [id(1): a, id(2): b, id(4): b],
            settled: [id(1): a, id(2): b, id(3): a]
        )
        XCTAssertEqual(targets, [id(1): a, id(2): b])
    }

    func testVisibleWindowsThatWereNotWrittenAreNotChecked() {
        let targets = renderCheckFrames(
            candidates: [id(1)], visible: [id(1): a, id(2): b], settled: [id(1): a, id(2): b]
        )
        XCTAssertEqual(targets.keys.sorted(), [id(1)])
    }

    func testSettleThatOnlyWroteParkedWindowsChecksNothing() {
        let targets = renderCheckFrames(
            candidates: [id(7), id(8)], visible: [id(1): a], settled: [id(7): a, id(8): b, id(1): a]
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testFailedWindowWithoutASettledFrameIsNotChecked() {
        let targets = renderCheckFrames(candidates: [id(1)], visible: [id(1): a], settled: [:])
        XCTAssertTrue(targets.isEmpty)
    }

    func testSettledFrameFeedsTheMismatchSearchWithoutAnotherRead() {
        let targets = renderCheckFrames(candidates: [id(1)], visible: [id(1): a], settled: [id(1): a])
        let server = [ServerWindow(pid: 10, bounds: a.offsetBy(dx: 300, dy: 0))]
        // Same size only: the sameSize pass pairs it, and the offset is a mismatch.
        let mismatches = findRenderMismatches(
            axFrames: targets, server: server, targets: targets, viewports: [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        )
        XCTAssertEqual(mismatches.map(\.id), [id(1)])
    }
}
