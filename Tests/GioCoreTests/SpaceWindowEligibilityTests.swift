import XCTest
@testable import GioCore

final class SpaceWindowEligibilityTests: XCTestCase {
    private let frame = CGRect(x: 110, y: 120, width: 300, height: 200)
    private let display = CGRect(x: 100, y: 100, width: 1000, height: 800)

    private func ax(_ id: Int, title: String? = "Editor", frame: CGRect? = nil,
                    display: CGRect? = nil) -> SpaceWindowEligibility.AXCandidate {
        .init(windowID: id, pid: 42, title: title, frame: frame ?? self.frame,
              displayBounds: display ?? self.display)
    }

    private func cg(_ title: String? = "Editor", frame: CGRect? = nil) -> SpaceWindowEligibility.CGWindow {
        .init(pid: 42, title: title, frame: frame ?? self.frame)
    }

    private func evaluate(_ windows: [SpaceWindowEligibility.AXCandidate],
                          _ onScreen: [SpaceWindowEligibility.CGWindow],
                          axGeneration: UInt64 = 2, cgGeneration: UInt64 = 2,
                          currentGeneration: UInt64 = 2) -> SpaceWindowEligibility.Result {
        SpaceWindowEligibility.evaluate(ax: windows, axGeneration: axGeneration,
            onScreen: onScreen, cgGeneration: cgGeneration, currentGeneration: currentGeneration)
    }

    func testUniqueExactMatchAndDeterministicInputOrder() {
        let second = SpaceWindowEligibility.AXCandidate(windowID: 3, pid: 7, title: "Other",
            frame: frame, displayBounds: display)
        let result = evaluate([second, ax(1)], [.init(pid: 7, title: "Other", frame: frame), cg()])
        XCTAssertEqual(result.eligibleWindowIDs, [3, 1])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testDuplicateAcrossSpacesSkipsEvenWithOneOnScreenWindow() {
        let result = evaluate([ax(1), ax(2)], [cg()])
        XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
        XCTAssertEqual(result.count(.ambiguousAX), 2)
        XCTAssertEqual(result.skipped.map(\.windowID), [1, 2])
    }

    func testDuplicateCGSkips() {
        let result = evaluate([ax(1)], [cg(), cg()])
        XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
        XCTAssertEqual(result.count(.ambiguousCG), 1)
    }

    func testMissingTitleInvalidFramesAndMissingCGNeverMatch() {
        let invalid = CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)
        let result = evaluate([ax(1, title: nil), ax(2, title: ""),
                               ax(3, frame: invalid), ax(4, frame: .zero), ax(5)], [])
        XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
        XCTAssertEqual(result.count(.missingMetadata), 2)
        XCTAssertEqual(result.count(.invalidFrame), 2)
        XCTAssertEqual(result.count(.missingOnScreenMatch), 1)
    }

    func testEitherSnapshotFromPreviousGenerationFailsClosed() {
        for generations: (UInt64, UInt64) in [(1, 2), (2, 1), (1, 1)] {
            let result = evaluate([ax(1)], [cg()], axGeneration: generations.0,
                                  cgGeneration: generations.1)
            XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
            XCTAssertEqual(result.count(.staleGeneration), 1)
        }
    }

    func testDisplayMismatchAndGeometryMismatchHaveZeroFalsePositives() {
        let otherDisplay = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let shifted = CGRect(x: 111, y: 120, width: 300, height: 200)
        let result = evaluate([ax(1, title: "Other", display: otherDisplay), ax(2)], [cg(frame: shifted)])
        XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
        XCTAssertEqual(result.count(.outOfDisplay), 1)
        XCTAssertEqual(result.count(.missingOnScreenMatch), 1)
    }

    func testPIDOnlyOrTitleOnlyNeverMatches() {
        let result = evaluate([ax(1)], [.init(pid: 7, title: "Editor", frame: frame),
                                          .init(pid: 42, title: "Other", frame: frame)])
        XCTAssertTrue(result.eligibleWindowIDs.isEmpty)
        XCTAssertEqual(result.count(.missingOnScreenMatch), 1)
    }
}
