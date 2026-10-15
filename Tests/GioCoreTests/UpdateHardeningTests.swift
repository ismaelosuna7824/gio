@testable import GioCore
import XCTest

/// UP-13, UP-14, UP-16, UP-17: the pure rules behind the updater hardening
/// (security review findings 0, 3, 5 and 6).
final class UpdateHardeningTests: XCTestCase {
    // MARK: Finding 0: Hardened Runtime

    func testHardenedRuntimeFlag() {
        XCTAssertTrue(codeSignatureHasHardenedRuntime(0x10000))
        XCTAssertTrue(codeSignatureHasHardenedRuntime(0x10002))
        XCTAssertFalse(codeSignatureHasHardenedRuntime(0))
        XCTAssertFalse(codeSignatureHasHardenedRuntime(0x2))
        XCTAssertFalse(codeSignatureHasHardenedRuntime(0x20000))
    }

    // MARK: Finding 5: the disk image's own signature

    func testImageRequirementPinsAnchorTeamAndCommonNameWithoutABundleIdentifier() throws {
        let requirement = try XCTUnwrap(updateImageRequirement(
            teamIdentifier: "2CAK428VHF", leafCommonName: "Apple Development: someone@example.com (DPYR37JY5V)"
        ))
        XCTAssertEqual(
            requirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"2CAK428VHF\""
                + " and certificate leaf[subject.CN] = \"Apple Development: someone@example.com (DPYR37JY5V)\""
        )
        XCTAssertFalse(requirement.contains("identifier"))
    }

    func testImageRequirementRefusesMissingOrQuotedValues() {
        XCTAssertNil(updateImageRequirement(teamIdentifier: nil, leafCommonName: "Apple Development: x"))
        XCTAssertNil(updateImageRequirement(teamIdentifier: "", leafCommonName: "Apple Development: x"))
        XCTAssertNil(updateImageRequirement(teamIdentifier: "2CAK428VHF", leafCommonName: nil))
        XCTAssertNil(updateImageRequirement(teamIdentifier: "2CAK428VHF", leafCommonName: ""))
        XCTAssertNil(updateImageRequirement(teamIdentifier: "2CAK428VHF", leafCommonName: "x\" or true"))
        XCTAssertNil(updateImageRequirement(teamIdentifier: "AB\"CD", leafCommonName: "x"))
    }

    // MARK: Finding 3: metadata of the staged copy

    func testRegularFilesBecomeUserWritableAndWorldReadableNeverGroupOrWorldWritable() {
        let me: UInt32 = 501
        XCTAssertEqual(stagedEntryDecision(mode: 0o777, owner: me, currentUser: me, kind: .file), .setMode(0o755))
        XCTAssertEqual(stagedEntryDecision(mode: 0o666, owner: me, currentUser: me, kind: .file), .setMode(0o644))
        XCTAssertEqual(stagedEntryDecision(mode: 0o400, owner: me, currentUser: me, kind: .file), .setMode(0o644))
        XCTAssertEqual(stagedEntryDecision(mode: 0o100, owner: me, currentUser: me, kind: .file), .setMode(0o755))
        XCTAssertEqual(stagedEntryDecision(mode: 0o644, owner: me, currentUser: me, kind: .file), .keep)
        XCTAssertEqual(stagedEntryDecision(mode: 0o755, owner: me, currentUser: me, kind: .file), .keep)
    }

    func testDirectoriesAlwaysGetSearchBits() {
        let me: UInt32 = 501
        XCTAssertEqual(stagedEntryDecision(mode: 0o777, owner: me, currentUser: me, kind: .directory), .setMode(0o755))
        XCTAssertEqual(stagedEntryDecision(mode: 0o700, owner: me, currentUser: me, kind: .directory), .setMode(0o755))
        XCTAssertEqual(stagedEntryDecision(mode: 0o644, owner: me, currentUser: me, kind: .directory), .setMode(0o755))
        XCTAssertEqual(stagedEntryDecision(mode: 0o755, owner: me, currentUser: me, kind: .directory), .keep)
    }

    func testSymlinksAreNeverChmoddedButStillOwnerChecked() {
        XCTAssertEqual(stagedEntryDecision(mode: 0o777, owner: 501, currentUser: 501, kind: .symlink), .keep)
        XCTAssertEqual(
            stagedEntryDecision(mode: 0o777, owner: 0, currentUser: 501, kind: .symlink), .refuse("an item owned by another user")
        )
    }

    func testForeignOwnersAndSetIDBitsAreRefused() {
        XCTAssertEqual(
            stagedEntryDecision(mode: 0o644, owner: 0, currentUser: 501, kind: .file), .refuse("an item owned by another user")
        )
        XCTAssertEqual(
            stagedEntryDecision(mode: 0o4755, owner: 501, currentUser: 501, kind: .file), .refuse("a setuid or setgid item")
        )
        XCTAssertEqual(
            stagedEntryDecision(mode: 0o2755, owner: 501, currentUser: 501, kind: .directory), .refuse("a setuid or setgid item")
        )
    }
}
