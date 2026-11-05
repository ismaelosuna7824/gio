import XCTest
@testable import GioCore

/// FI-15: a window purged by absence (a complete scan no longer lists it)
/// must be confirmed gone by the window server first. During a screen lock
/// the apps' Accessibility lists empty out while the windows stay on screen.
final class VanishConfirmationTests: XCTestCase {
    private let a = WindowID(pid: 7, elementID: 1)
    private let b = WindowID(pid: 7, elementID: 2)
    private let c = WindowID(pid: 8, elementID: 3)

    func testAWindowTheWindowServerStillListsIsKept() {
        let result = confirmedVanished(candidates: [a], numbers: [a: 41], liveNumbers: [41, 99], destroyed: [])
        XCTAssertEqual(result, VanishConfirmation(purge: [], kept: [a]))
    }

    func testAWindowWhoseNumberIsGoneIsPurged() {
        let result = confirmedVanished(candidates: [a], numbers: [a: 41], liveNumbers: [99], destroyed: [])
        XCTAssertEqual(result, VanishConfirmation(purge: [a], kept: []))
    }

    func testAWindowWithoutARecordedNumberIsPurgedAsBefore() {
        let result = confirmedVanished(candidates: [a], numbers: [:], liveNumbers: [41], destroyed: [])
        XCTAssertEqual(result, VanishConfirmation(purge: [a], kept: []))
    }

    func testADestroyedNoticeIsProofWhateverTheListSays() {
        let result = confirmedVanished(candidates: [a], numbers: [a: 41], liveNumbers: [41], destroyed: [a])
        XCTAssertEqual(result, VanishConfirmation(purge: [a], kept: []))
    }

    func testMixedCandidatesComeBackSorted() {
        let result = confirmedVanished(
            candidates: [c, b, a], numbers: [a: 41, b: 42, c: 43], liveNumbers: [43, 41], destroyed: []
        )
        XCTAssertEqual(result, VanishConfirmation(purge: [b], kept: [a, c]))
    }

    func testTheWindowServerIsAskedOnlyWhenANumberCouldKeepAWindow() {
        XCTAssertFalse(vanishNeedsWindowServer(candidates: [], numbers: [a: 41], destroyed: []))
        XCTAssertFalse(vanishNeedsWindowServer(candidates: [a], numbers: [:], destroyed: []))
        XCTAssertFalse(vanishNeedsWindowServer(candidates: [a], numbers: [a: 41], destroyed: [a]))
        XCTAssertTrue(vanishNeedsWindowServer(candidates: [a, b], numbers: [b: 42], destroyed: [a]))
    }
}
