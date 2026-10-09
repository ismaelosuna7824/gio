@testable import GioCore
import XCTest

/// UP-01: release tags are semver (`v` optional); prereleases order below
/// their release and by identifier, numeric before alphanumeric.
final class SemanticVersionTests: XCTestCase {
    func testParsesPlainAndTaggedVersions() throws {
        let plain = try XCTUnwrap(SemanticVersion("1.2.3"))
        XCTAssertEqual(plain.major, 1)
        XCTAssertEqual(plain.minor, 2)
        XCTAssertEqual(plain.patch, 3)
        XCTAssertFalse(plain.isPrerelease)
        XCTAssertEqual(SemanticVersion("v1.2.3"), plain)
        let beta = try XCTUnwrap(SemanticVersion("v0.2.0-beta.1"))
        XCTAssertEqual(beta.prerelease, ["beta", "1"])
        XCTAssertTrue(beta.isPrerelease)
        XCTAssertEqual(beta.description, "0.2.0-beta.1")
        XCTAssertEqual(beta.tag, "v0.2.0-beta.1")
    }

    func testBuildMetadataIsIgnored() {
        XCTAssertEqual(SemanticVersion("1.0.0+42"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("1.0.0-rc.1+sha.abc")?.prerelease, ["rc", "1"])
    }

    func testRejectsMalformedVersions() {
        for text in ["", "v", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "a.b.c", "1.2.3-", "1.2.3-beta..1",
                     "1.2.3-beta.01", "1.2.3-be_ta", "-1.2.3", "1.2.3 ", "vv1.2.3"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrderingFollowsSemver() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let versions = try ordered.map { try XCTUnwrap(SemanticVersion($0)) }
        for index in versions.indices.dropLast() {
            XCTAssertLessThan(versions[index], versions[index + 1], "\(ordered[index]) < \(ordered[index + 1])")
        }
        XCTAssertEqual(versions.shuffled().sorted(), versions)
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("0.9.9")), try XCTUnwrap(SemanticVersion("0.10.0")))
    }

    func testDevStampedBuildEqualsItsTag() {
        // Local builds are stamped `<tag>+dev`; precedence ignores metadata.
        XCTAssertEqual(SemanticVersion("0.2.0+dev"), SemanticVersion("0.2.0"))
    }
}
