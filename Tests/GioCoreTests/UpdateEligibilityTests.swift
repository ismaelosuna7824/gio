@testable import GioCore
import XCTest

/// UP-03: where the running app may replace itself, and the signature and
/// bundle checks every downloaded app must pass.
final class UpdateEligibilityTests: XCTestCase {
    private func facts(
        _ path: String = "/Applications/Gio.app", writable: Bool = true, version: String = "0.2.0",
        team: String? = "2CAK428VHF"
    ) -> InstallLocationFacts {
        InstallLocationFacts(bundlePath: path, parentWritable: writable, runningVersion: version, teamIdentifier: team)
    }

    func testReleaseInApplicationsIsInstallable() {
        XCTAssertEqual(installEligibility(facts()), .installable(target: "/Applications/Gio.app"))
        XCTAssertEqual(
            installEligibility(facts("/Users/me/Applications/Gio.app")),
            .installable(target: "/Users/me/Applications/Gio.app")
        )
    }

    func testTrailingSlashIsNormalized() {
        XCTAssertEqual(installEligibility(facts("/Applications/Gio.app/")), .installable(target: "/Applications/Gio.app"))
    }

    func testBareExecutableOnlyNotifies() {
        XCTAssertEqual(installEligibility(facts("/Users/me/gio/.build/debug")), .notifyOnly(.notAppBundle))
    }

    func testBuildFoldersOnlyNotify() {
        for path in [
            "/Users/me/Library/Developer/Xcode/DerivedData/Gio-abc/Build/Products/Debug/Gio.app",
            "/Users/me/gio /.build/GioAutoTeam/Build/Products/Debug/Gio.app",
            "/tmp/out/Build/Products/Release/Gio.app",
        ] {
            XCTAssertEqual(installEligibility(facts(path)), .notifyOnly(.buildFolder), path)
        }
    }

    func testTranslocatedOrReadOnlyCopiesAskToMoveToApplications() {
        let translocated = "/private/var/folders/x/T/AppTranslocation/1234/d/Gio.app"
        XCTAssertEqual(installEligibility(facts(translocated)), .notifyOnly(.translocated))
        XCTAssertEqual(installEligibility(facts("/Volumes/Gio/Gio.app", writable: false)), .notifyOnly(.readOnlyLocation))
        XCTAssertTrue(UpdateIneligibility.translocated.suggestion.contains("/Applications"))
        XCTAssertTrue(UpdateIneligibility.readOnlyLocation.suggestion.contains("/Applications"))
    }

    func testDevelopmentAndUnsignedBuildsOnlyNotify() {
        XCTAssertEqual(installEligibility(facts(version: "0.0.0-dev")), .notifyOnly(.developmentBuild))
        XCTAssertEqual(installEligibility(facts(version: "0.2.0+dev")), .notifyOnly(.developmentBuild))
        XCTAssertEqual(installEligibility(facts(team: nil)), .notifyOnly(.unsignedBuild))
        XCTAssertEqual(installEligibility(facts(team: "")), .notifyOnly(.unsignedBuild))
    }

    func testEveryReasonExplainsItself() {
        for reason in UpdateIneligibility.allCases {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.suggestion.isEmpty)
        }
    }

    func testRequirementCombinesDesignatedTeamAndIdentifier() throws {
        let designated = #"identifier "dev.gio.windowmanager" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Someone (DPYR37JY5V)""#
        let requirement = try XCTUnwrap(updateCodeRequirement(
            designated: designated, teamIdentifier: "2CAK428VHF", bundleIdentifier: "dev.gio.windowmanager"
        ))
        XCTAssertEqual(
            requirement,
            "(\(designated)) and identifier \"dev.gio.windowmanager\" and anchor apple generic"
                + " and certificate leaf[subject.OU] = \"2CAK428VHF\""
        )
        XCTAssertEqual(
            updateCodeRequirement(designated: nil, teamIdentifier: "2CAK428VHF", bundleIdentifier: "dev.gio.windowmanager"),
            "identifier \"dev.gio.windowmanager\" and anchor apple generic and certificate leaf[subject.OU] = \"2CAK428VHF\""
        )
    }

    func testRequirementRefusesUnsignedOrOddIdentities() {
        XCTAssertNil(updateCodeRequirement(designated: nil, teamIdentifier: nil, bundleIdentifier: "dev.gio.windowmanager"))
        XCTAssertNil(updateCodeRequirement(designated: nil, teamIdentifier: "", bundleIdentifier: "dev.gio.windowmanager"))
        // Quotes would let a value escape the requirement string.
        XCTAssertNil(updateCodeRequirement(designated: nil, teamIdentifier: "AB\"CD", bundleIdentifier: "x"))
        XCTAssertNil(updateCodeRequirement(designated: nil, teamIdentifier: "2CAK428VHF", bundleIdentifier: "x\" or true"))
    }

    func testStagedBundleMustMatchIdentifierAndVersion() throws {
        let version = try XCTUnwrap(SemanticVersion("0.3.0"))
        XCTAssertNil(checkUpdateBundle(
            bundleIdentifier: "dev.gio.windowmanager", shortVersion: "0.3.0",
            expectedBundleIdentifier: "dev.gio.windowmanager", expectedVersion: version
        ))
        XCTAssertEqual(
            checkUpdateBundle(
                bundleIdentifier: "com.other", shortVersion: "0.3.0",
                expectedBundleIdentifier: "dev.gio.windowmanager", expectedVersion: version
            ),
            .bundleMismatch("bundle identifier com.other")
        )
        XCTAssertEqual(
            checkUpdateBundle(
                bundleIdentifier: "dev.gio.windowmanager", shortVersion: "0.2.9",
                expectedBundleIdentifier: "dev.gio.windowmanager", expectedVersion: version
            ),
            .bundleMismatch("version 0.2.9, expected 0.3.0")
        )
        XCTAssertEqual(
            checkUpdateBundle(
                bundleIdentifier: nil, shortVersion: nil,
                expectedBundleIdentifier: "dev.gio.windowmanager", expectedVersion: version
            ),
            .bundleMismatch("bundle identifier missing")
        )
    }
}
