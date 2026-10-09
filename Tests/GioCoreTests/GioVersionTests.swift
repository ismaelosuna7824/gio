import XCTest
@testable import GioCore

/// RL-01: one version source. The app bundle's `CFBundleShortVersionString`
/// (fed by `MARKETING_VERSION`) wins; SwiftPM/CLI builds without a bundle
/// version fall back to the build-time constant.
final class GioVersionTests: XCTestCase {
    func testBundleShortVersionWins() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0-beta.1", "CFBundleVersion": "17"]
        XCTAssertEqual(resolveGioVersion(infoDictionary: info), "0.2.0-beta.1")
    }

    func testMissingDictionaryFallsBackToBuildVersion() {
        XCTAssertEqual(resolveGioVersion(infoDictionary: nil), gioBuildVersion)
    }

    func testMissingKeyFallsBackToBuildVersion() {
        XCTAssertEqual(resolveGioVersion(infoDictionary: ["CFBundleVersion": "3"]), gioBuildVersion)
    }

    func testBlankOrNonStringFallsBack() {
        XCTAssertEqual(resolveGioVersion(infoDictionary: ["CFBundleShortVersionString": "  "]), gioBuildVersion)
        XCTAssertEqual(resolveGioVersion(infoDictionary: ["CFBundleShortVersionString": 2]), gioBuildVersion)
    }

    func testUnexpandedBuildSettingFallsBack() {
        let info: [String: Any] = ["CFBundleShortVersionString": "$(MARKETING_VERSION)"]
        XCTAssertEqual(resolveGioVersion(infoDictionary: info), gioBuildVersion)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(resolveGioVersion(infoDictionary: ["CFBundleShortVersionString": " 1.4.0\n"]), "1.4.0")
    }

    func testBuildVersionIsTheDevMarker() {
        XCTAssertEqual(gioBuildVersion, "0.0.0-dev")
    }

    func testTestRunnerHasNoGioBundleVersion() {
        // xctest's own bundle is not Gio: the computed version must still be non-empty.
        XCTAssertFalse(gioVersion.isEmpty)
    }

    func testDevBuildVersions() {
        XCTAssertTrue(isDevBuildVersion("0.0.0-dev"))
        XCTAssertTrue(isDevBuildVersion("0.2.0+dev"))
        XCTAssertTrue(isDevBuildVersion("0.2.0-beta.1+dev"))
        XCTAssertFalse(isDevBuildVersion("0.2.0"))
        XCTAssertFalse(isDevBuildVersion("0.2.0-beta.1"))
        XCTAssertFalse(isDevBuildVersion("1.0.0-devtools"))
    }
}
