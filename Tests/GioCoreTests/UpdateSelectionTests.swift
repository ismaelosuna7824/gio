@testable import GioCore
import XCTest

/// UP-02: GitHub release JSON, asset pairing, checksum files and the choice
/// of the newest applicable release per channel.
final class UpdateSelectionTests: XCTestCase {
    static let fixture = """
    [
      {"tag_name": "v0.3.0", "name": "Gio 0.3.0", "draft": true, "prerelease": false, "body": "draft",
       "html_url": "https://github.com/o/r/releases/tag/v0.3.0", "assets": []},
      {"tag_name": "v0.2.1-beta.1", "name": null, "draft": false, "prerelease": true, "body": "beta notes",
       "html_url": "https://github.com/o/r/releases/tag/v0.2.1-beta.1",
       "assets": [
         {"name": "Gio-0.2.1-beta.1.dmg", "size": 1000, "url": "https://api.github.com/repos/o/r/releases/assets/11",
          "browser_download_url": "https://github.com/o/r/releases/download/v0.2.1-beta.1/Gio-0.2.1-beta.1.dmg"},
         {"name": "Gio-0.2.1-beta.1.dmg.sha256", "size": 90, "url": "https://api.github.com/repos/o/r/releases/assets/12",
          "browser_download_url": "https://github.com/o/r/releases/download/v0.2.1-beta.1/Gio-0.2.1-beta.1.dmg.sha256"}
       ]},
      {"tag_name": "v0.2.0", "name": "Gio 0.2.0", "draft": false, "prerelease": false, "body": "## New\\n- updates",
       "html_url": "https://github.com/o/r/releases/tag/v0.2.0", "published_at": "2026-10-08T10:00:00Z",
       "assets": [
         {"name": "Gio-0.2.0.dmg", "size": 2048, "url": "https://api.github.com/repos/o/r/releases/assets/21",
          "browser_download_url": "https://github.com/o/r/releases/download/v0.2.0/Gio-0.2.0.dmg", "extra": 1},
         {"name": "Gio-0.2.0.dmg.sha256", "size": 81, "url": "https://api.github.com/repos/o/r/releases/assets/22",
          "browser_download_url": "https://github.com/o/r/releases/download/v0.2.0/Gio-0.2.0.dmg.sha256"}
       ]},
      {"tag_name": "nightly", "draft": false, "prerelease": true, "assets": []},
      {"tag_name": "v0.1.5", "draft": false, "prerelease": false, "body": "no dmg", "assets": [
         {"name": "Gio-0.1.5.zip", "size": 5, "url": "u", "browser_download_url": "b"}]}
    ]
    """

    private func releases() throws -> [GitHubRelease] {
        try decodeGitHubReleases(Data(Self.fixture.utf8))
    }

    private func version(_ text: String) throws -> SemanticVersion {
        try XCTUnwrap(SemanticVersion(text))
    }

    func testDecodesTheReleaseFixture() throws {
        let all = try releases()
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all[0].tagName, "v0.3.0")
        XCTAssertTrue(all[0].draft)
        XCTAssertTrue(all[1].prerelease)
        XCTAssertNil(all[1].name)
        XCTAssertEqual(all[2].body, "## New\n- updates")
        XCTAssertEqual(all[2].htmlURL, "https://github.com/o/r/releases/tag/v0.2.0")
        XCTAssertEqual(all[2].assets.first?.size, 2048)
        XCTAssertEqual(all[2].assets.first?.url, "https://api.github.com/repos/o/r/releases/assets/21")
        XCTAssertEqual(
            all[2].assets.first?.browserDownloadURL,
            "https://github.com/o/r/releases/download/v0.2.0/Gio-0.2.0.dmg"
        )
        XCTAssertNil(all[3].body)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try decodeGitHubReleases(Data("{\"message\": \"Not Found\"}".utf8)))
    }

    func testPairsTheDMGWithItsChecksum() throws {
        let release = try releases()[2]
        let pair = try XCTUnwrap(pairUpdateAssets(in: release, version: try version("0.2.0")))
        XCTAssertEqual(pair.dmg.name, "Gio-0.2.0.dmg")
        XCTAssertEqual(pair.checksum.name, "Gio-0.2.0.dmg.sha256")
        XCTAssertNil(pairUpdateAssets(in: try releases()[4], version: try version("0.1.5")))
        // A DMG named for another version is not this release's.
        XCTAssertNil(pairUpdateAssets(in: release, version: try version("0.2.1")))
    }

    func testStableChannelPicksNewestRelease() throws {
        let selection = selectUpdate(from: try releases(), running: try version("0.1.0"), includePrereleases: false)
        guard case .available(let update) = selection else {
            return XCTFail("expected an update, got \(selection)")
        }
        XCTAssertEqual(update.version, try version("0.2.0"))
        XCTAssertEqual(update.tag, "v0.2.0")
        XCTAssertEqual(update.notes, "## New\n- updates")
        XCTAssertFalse(update.isPrerelease)
        XCTAssertEqual(update.dmg.size, 2048)
        XCTAssertEqual(update.pageURL, "https://github.com/o/r/releases/tag/v0.2.0")
    }

    func testDraftsAreNeverOffered() throws {
        let selection = selectUpdate(from: try releases(), running: try version("0.2.0"), includePrereleases: false)
        XCTAssertEqual(selection, .upToDate)
    }

    func testBetaChannelPicksNewerPrerelease() throws {
        let selection = selectUpdate(from: try releases(), running: try version("0.2.0"), includePrereleases: true)
        guard case .available(let update) = selection else {
            return XCTFail("expected the beta, got \(selection)")
        }
        XCTAssertEqual(update.version, try version("0.2.1-beta.1"))
        XCTAssertTrue(update.isPrerelease)
    }

    func testReleasesWithoutPairedAssetsAreSkipped() throws {
        let selection = selectUpdate(from: try releases(), running: try version("0.1.0"), includePrereleases: false)
        XCTAssertNotEqual(selection, .upToDate)
        let onlyZip = try releases().filter { $0.tagName == "v0.1.5" }
        XCTAssertEqual(selectUpdate(from: onlyZip, running: try version("0.1.0"), includePrereleases: false), .upToDate)
    }

    func testOlderOrEqualIsUpToDate() throws {
        XCTAssertEqual(
            selectUpdate(from: try releases(), running: try version("0.3.0"), includePrereleases: true), .upToDate
        )
        XCTAssertEqual(selectUpdate(from: [], running: try version("0.1.0"), includePrereleases: true), .upToDate)
    }

    func testChannelRules() {
        XCTAssertFalse(includesPrereleases(runningVersion: "0.2.0", includeBetas: false))
        XCTAssertTrue(includesPrereleases(runningVersion: "0.2.0", includeBetas: true))
        // A beta user stays on the beta train.
        XCTAssertTrue(includesPrereleases(runningVersion: "0.2.0-beta.1", includeBetas: false))
        // Local development builds are not a beta opt-in.
        XCTAssertFalse(includesPrereleases(runningVersion: "0.0.0-dev", includeBetas: false))
        XCTAssertFalse(includesPrereleases(runningVersion: "0.2.0+dev", includeBetas: false))
        XCTAssertFalse(includesPrereleases(runningVersion: "garbage", includeBetas: false))
    }

    func testChecksumFile() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(parseChecksumFile("\(hex)  Gio-0.2.0.dmg\n", expectedFileName: "Gio-0.2.0.dmg"), hex)
        XCTAssertEqual(parseChecksumFile(hex.uppercased() + " *Gio-0.2.0.dmg", expectedFileName: "Gio-0.2.0.dmg"), hex)
        XCTAssertEqual(parseChecksumFile(hex, expectedFileName: "Gio-0.2.0.dmg"), hex)
        XCTAssertNil(parseChecksumFile("\(hex)  Other.dmg", expectedFileName: "Gio-0.2.0.dmg"))
        XCTAssertNil(parseChecksumFile("abc  Gio-0.2.0.dmg", expectedFileName: "Gio-0.2.0.dmg"))
        XCTAssertNil(parseChecksumFile(String(repeating: "zz", count: 32), expectedFileName: "Gio-0.2.0.dmg"))
        XCTAssertNil(parseChecksumFile("", expectedFileName: "Gio-0.2.0.dmg"))
    }

    func testUpdateRepositoryFromInfoDictionary() {
        XCTAssertEqual(updateRepository(infoDictionary: nil), defaultUpdateRepository)
        XCTAssertEqual(defaultUpdateRepository, "ismaelosuna7824/gio")
        XCTAssertEqual(updateRepository(infoDictionary: ["GioUpdateRepository": "someone/fork"]), "someone/fork")
        XCTAssertEqual(updateRepository(infoDictionary: ["GioUpdateRepository": ""]), defaultUpdateRepository)
        XCTAssertEqual(updateRepository(infoDictionary: ["GioUpdateRepository": "$(GIO_UPDATE_REPOSITORY)"]), defaultUpdateRepository)
        XCTAssertEqual(updateRepository(infoDictionary: ["GioUpdateRepository": "no-slash"]), defaultUpdateRepository)
        XCTAssertEqual(updateRepository(infoDictionary: ["GioUpdateRepository": "a/b/c"]), defaultUpdateRepository)
    }
}
