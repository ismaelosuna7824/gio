import Foundation
@testable import GioCore
@testable import GioMacOS
import XCTest

/// UP-08: download, checksum, mount, signature and staging over fakes; the
/// smoke tests at the end build a real DMG with a dummy app in a temp dir.
final class UpdatePreparerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gio-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Serves files from a dictionary of asset name → bytes.
    final class FakeDownloader: UpdateAssetDownloading, @unchecked Sendable {
        var files: [String: Data] = [:]
        private(set) var downloaded: [String] = []

        func download(
            _ asset: GitHubReleaseAsset, to directory: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> URL {
            downloaded.append(asset.name)
            guard let data = files[asset.name] else {
                throw URLError(.fileDoesNotExist)
            }
            progress(0.5)
            let url = directory.appendingPathComponent(asset.name)
            try data.write(to: url)
            progress(1)
            return url
        }
    }

    /// "Mounts" by copying a prepared folder to the mount point.
    final class FakeMounter: DiskImageMounting, @unchecked Sendable {
        let contents: URL
        private(set) var attached = 0
        private(set) var detached = 0

        init(contents: URL) {
            self.contents = contents
        }

        func attach(_ image: URL, at mountPoint: URL) throws {
            attached += 1
            try FileManager.default.copyItem(at: contents, to: mountPoint)
        }

        func detach(_ mountPoint: URL) {
            detached += 1
            try? FileManager.default.removeItem(at: mountPoint)
        }
    }

    struct FakeVerifier: CodeSignatureVerifying {
        var verdict: Result<Void, UpdateFailure>
        var imageVerdict: Result<Void, UpdateFailure> = .success(())
        func verify(appAt url: URL) -> Result<Void, UpdateFailure> {
            verdict
        }

        func verify(imageAt url: URL) -> Result<Void, UpdateFailure> {
            imageVerdict
        }
    }

    private func makeDummyApp(in folder: URL, bundleID: String = "dev.gio.windowmanager", version: String = "0.3.0") throws {
        let contents = folder.appendingPathComponent("Gio.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleExecutable": "Gio",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: contents.appendingPathComponent("MacOS/Gio"))
    }

    private func update(version: String = "0.3.0") -> AvailableUpdate {
        let v = SemanticVersion(version)!
        let names = updateAssetNames(for: v)
        return AvailableUpdate(
            version: v, tag: v.tag, notes: "", isPrerelease: false, pageURL: nil,
            dmg: GitHubReleaseAsset(name: names.dmg, size: 4, url: "https://x/dmg", browserDownloadURL: "https://x/dmg"),
            checksum: GitHubReleaseAsset(name: names.checksum, size: 1, url: "https://x/sum", browserDownloadURL: "https://x/sum")
        )
    }

    private struct Fixture {
        let preparer: UpdatePreparer
        let downloader: FakeDownloader
        let mounter: FakeMounter
        let target: String
    }

    private func fixture(
        dmgBytes: Data = Data("fake disk image".utf8), checksum: String? = nil,
        verdict: Result<Void, UpdateFailure> = .success(()), imageVerdict: Result<Void, UpdateFailure> = .success(()),
        bundleID: String = "dev.gio.windowmanager", appVersion: String = "0.3.0", includeApp: Bool = true
    ) throws -> Fixture {
        let image = root.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        if includeApp {
            try makeDummyApp(in: image, bundleID: bundleID, version: appVersion)
        }
        let installed = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let downloader = FakeDownloader()
        let names = updateAssetNames(for: SemanticVersion("0.3.0")!)
        downloader.files[names.dmg] = dmgBytes
        let digest = checksum ?? sha256Hex(of: dmgBytes)
        downloader.files[names.checksum] = Data("\(digest)  \(names.dmg)\n".utf8)
        let mounter = FakeMounter(contents: image)
        let preparer = UpdatePreparer(
            downloader: downloader, mounter: mounter, verifier: { FakeVerifier(verdict: verdict, imageVerdict: imageVerdict) },
            bundleIdentifier: "dev.gio.windowmanager", workRoot: root.appendingPathComponent("work")
        )
        return Fixture(
            preparer: preparer, downloader: downloader, mounter: mounter,
            target: installed.appendingPathComponent("Gio.app").path
        )
    }

    /// Hidden entries the updater left next to the target (staging or aside folders).
    private func leftovers(nextTo target: String) throws -> [String] {
        let folder = (target as NSString).deletingLastPathComponent
        return try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasPrefix(".") }
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    func testVerifiedAppIsStagedInAFreshPrivateFolderNextToTheTarget() async throws {
        let fx = try fixture()
        let progress = ProgressLog()
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { progress.add($0) }, verifying: {})
        let staged = try result.get()
        let folder = try XCTUnwrap(updateStagingDirectory(ofStagedApp: staged))
        XCTAssertEqual((folder as NSString).deletingLastPathComponent, (fx.target as NSString).deletingLastPathComponent)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged + "/Contents/Info.plist"))
        XCTAssertEqual(fx.mounter.attached, 1)
        XCTAssertEqual(fx.mounter.detached, 1)
        XCTAssertEqual(progress.values.last, 1)
        // The download folder is gone afterwards.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path), [])
    }

    func testChecksumMismatchRefusesBeforeMounting() async throws {
        let fx = try fixture(checksum: String(repeating: "0", count: 64))
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .checksumMismatch)
        XCTAssertEqual(fx.mounter.attached, 0)
        XCTAssertEqual(try leftovers(nextTo: fx.target), [])
    }

    func testStagingFolderCreationFailureRefuses() async throws {
        let fx = try fixture()
        let folder = (fx.target as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        }
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .stagingFailed("cannot create a private staging folder"))
        XCTAssertEqual(fx.mounter.detached, 1)
        XCTAssertEqual(try leftovers(nextTo: fx.target), [])
    }

    func testImageSignatureIsCheckedBeforeMounting() async throws {
        let fx = try fixture(imageVerdict: .failure(.signatureRejected("different developer or bundle")))
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .signatureRejected("different developer or bundle"))
        XCTAssertEqual(fx.mounter.attached, 0)
        XCTAssertEqual(try leftovers(nextTo: fx.target), [])
    }

    func testStagedCopyIsNormalisedWithoutACLsBeforeItsSecondCheck() async throws {
        let fx = try fixture()
        let image = root.appendingPathComponent("image/Gio.app")
        let binary = image.appendingPathComponent("Contents/MacOS/Gio").path
        let plist = image.appendingPathComponent("Contents/Info.plist").path
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: plist)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: image.appendingPathComponent("Contents").path
        )
        XCTAssertEqual(runTool("/bin/chmod", ["+a", "everyone allow write", plist]), 0)
        let staged = try await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {}).get()
        XCTAssertEqual(try mode(staged + "/Contents/MacOS/Gio"), 0o755)
        XCTAssertEqual(try mode(staged + "/Contents/Info.plist"), 0o644)
        XCTAssertEqual(try mode(staged + "/Contents"), 0o755)
        XCTAssertFalse(try toolOutput("/bin/ls", ["-le", staged + "/Contents/Info.plist"]).contains("allow write"))
    }

    func testSetIDItemsNeverReachTheStagedCopy() async throws {
        // ditto (not root) drops the bits; the tree check refuses them if they ever survive a copy.
        let fx = try fixture()
        let binary = root.appendingPathComponent("image/Gio.app/Contents/MacOS/Gio").path
        XCTAssertEqual(runTool("/bin/chmod", ["4755", binary]), 0)
        let staged = try await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {}).get()
        XCTAssertEqual(try mode(staged + "/Contents/MacOS/Gio"), 0o755)

        let tree = root.appendingPathComponent("tree")
        try makeDummyApp(in: tree)
        XCTAssertEqual(runTool("/bin/chmod", ["4755", tree.appendingPathComponent("Gio.app/Contents/MacOS/Gio").path]), 0)
        XCTAssertEqual(normaliseStagedTree(at: tree.appendingPathComponent("Gio.app").path), "a setuid or setgid item")
    }

    func testUnreadableChecksumRefuses() async throws {
        let fx = try fixture(checksum: "not-a-digest")
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .checksumUnreadable)
    }

    func testSignatureMismatchRefusesAndDetaches() async throws {
        let fx = try fixture(verdict: .failure(.signatureRejected("team")))
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .signatureRejected("team"))
        XCTAssertEqual(fx.mounter.detached, 1)
        XCTAssertEqual(try leftovers(nextTo: fx.target), [])
    }

    func testUnsignedRunningAppRefuses() async throws {
        let fx = try fixture()
        let preparer = UpdatePreparer(
            downloader: fx.downloader, mounter: fx.mounter, verifier: { nil },
            bundleIdentifier: "dev.gio.windowmanager", workRoot: root.appendingPathComponent("work")
        )
        let result = await preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .notEligible(.unsignedBuild))
        XCTAssertEqual(fx.downloader.downloaded, [])
    }

    func testWrongBundleOrVersionRefuses() async throws {
        let other = try fixture(bundleID: "com.example.other")
        let result = await other.preparer.prepare(update(), target: other.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .bundleMismatch("bundle identifier com.example.other"))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = try fixture(appVersion: "0.2.0")
        let staleResult = await stale.preparer.prepare(update(), target: stale.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(staleResult.failure, .bundleMismatch("version 0.2.0, expected 0.3.0"))
    }

    func testImageWithoutGioAppRefuses() async throws {
        let fx = try fixture(includeApp: false)
        let result = await fx.preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        XCTAssertEqual(result.failure, .appMissing)
    }

    func testFileDigest() throws {
        let file = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(
            try sha256Hex(ofFileAt: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: Smoke: a real DMG in a temp dir (never the installed Gio)

    private func makeRealDMG(version: String = "0.3.0") throws -> (dmg: URL, data: Data) {
        let source = root.appendingPathComponent("dmg-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeDummyApp(in: source, version: version)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications")
        )
        let dmg = root.appendingPathComponent("Gio-\(version).dmg")
        let status = runTool("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-volname", "Gio", "-srcfolder", source.path, "-format", "UDZO", dmg.path])
        guard status == 0 else {
            throw XCTSkip("hdiutil create unavailable here (status \(status))")
        }
        return (dmg, try Data(contentsOf: dmg))
    }

    private func toolOutput(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private func runTool(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testSmokeRealDMGIsVerifiedAndStaged() async throws {
        let (_, bytes) = try makeRealDMG()
        let fx = try fixture(dmgBytes: bytes)
        let preparer = UpdatePreparer(
            downloader: fx.downloader, mounter: HdiutilMounter(), verifier: { FakeVerifier(verdict: .success(())) },
            bundleIdentifier: "dev.gio.windowmanager", workRoot: root.appendingPathComponent("work")
        )
        let staged = try await preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {}).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged + "/Contents/MacOS/Gio"))
        // Detached: no mount point left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path), [])
    }

    func testSmokeRealSignatureCheckRefusesAnUnsignedApp() async throws {
        let (_, bytes) = try makeRealDMG()
        let fx = try fixture(dmgBytes: bytes)
        let requirement = try XCTUnwrap(updateCodeRequirement(
            designated: nil, teamIdentifier: "2CAK428VHF", bundleIdentifier: "dev.gio.windowmanager"
        ))
        let imageRequirement = try XCTUnwrap(updateImageRequirement(
            teamIdentifier: "2CAK428VHF", leafCommonName: "Apple Development: someone@example.com (DPYR37JY5V)"
        ))
        let preparer = UpdatePreparer(
            downloader: fx.downloader, mounter: HdiutilMounter(),
            verifier: { RequirementSignatureVerifier(requirement: requirement, imageRequirement: imageRequirement) },
            bundleIdentifier: "dev.gio.windowmanager", workRoot: root.appendingPathComponent("work")
        )
        let result = await preparer.prepare(update(), target: fx.target, progress: { _ in }, verifying: {})
        guard case .signatureRejected? = result.failure else {
            return XCTFail("expected a signature refusal, got \(result)")
        }
        XCTAssertEqual(try leftovers(nextTo: fx.target), [])
    }

    /// A dummy Gio.app whose executable is a real Mach-O, signed ad hoc, so
    /// `codesign --verify -R=...` in the helper has something to check.
    private func makeSignedDummyApp(in folder: URL, version: String) throws -> String {
        try makeDummyApp(in: folder, version: version)
        let app = folder.appendingPathComponent("Gio.app").path
        let binary = app + "/Contents/MacOS/Gio"
        try FileManager.default.removeItem(atPath: binary)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binary)
        guard runTool("/usr/bin/codesign", ["--force", "--sign", "-", app]) == 0 else {
            throw XCTSkip("codesign unavailable here")
        }
        return app
    }

    private struct SwapRun {
        let status: Int32
        let target: String
        let folder: URL
        let log: String
        let script: URL
    }

    private func runSwap(requirement: String) throws -> SwapRun {
        let folder = root.appendingPathComponent("My Apps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = try makeSignedDummyApp(in: folder, version: "0.2.0")
        let stageDir = try XCTUnwrap(makeUpdateStagingDirectory(target: target))
        let built = root.appendingPathComponent("built")
        let staged = stageDir + "/Gio.app"
        try FileManager.default.moveItem(atPath: try makeSignedDummyApp(in: built, version: "0.3.0"), toPath: staged)
        let log = root.appendingPathComponent("Logs/update.log").path
        let script = root.appendingPathComponent("helper.sh")
        let plan = UpdateInstallPlan(
            target: target, staged: staged, stagingDirectory: stageDir, requirement: requirement,
            waitPIDs: [999_999], logPath: log, relaunch: false, waitSeconds: 2
        )
        try updateInstallScript(plan).write(to: script, atomically: true, encoding: .utf8)
        return SwapRun(status: runTool("/bin/sh", [script.path]), target: target, folder: folder, log: log, script: script)
    }

    private func installedVersion(_ target: String) -> String? {
        NSDictionary(contentsOfFile: target + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }

    func testSmokeVerifierRequiresHardenedRuntime() throws {
        let app = URL(fileURLWithPath: try makeSignedDummyApp(in: root.appendingPathComponent("plain"), version: "0.3.0"))
        let verifier = RequirementSignatureVerifier(
            requirement: #"identifier "dev.gio.windowmanager""#, imageRequirement: "anchor apple generic"
        )
        XCTAssertEqual(verifier.verify(appAt: app).failure, .signatureRejected("no hardened runtime"))
        XCTAssertEqual(runTool("/usr/bin/codesign", ["--force", "--options", "runtime", "--sign", "-", app.path]), 0)
        XCTAssertNil(verifier.verify(appAt: app).failure)
    }

    func testSmokeInstallScriptSwapsBundlesInATempFolder() throws {
        let run = try runSwap(requirement: #"identifier "dev.gio.windowmanager""#)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(installedVersion(run.target), "0.3.0")
        XCTAssertEqual(try leftovers(nextTo: run.target), [], "staging and aside folders are gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.script.path), "the helper deletes itself")
        let logText = try String(contentsOfFile: run.log, encoding: .utf8)
        XCTAssertTrue(logText.contains("installed"))
    }

    func testSmokeInstallScriptRollsBackAnAppThatFailsTheRequirementAfterTheSwap() throws {
        let run = try runSwap(requirement: #"identifier "com.example.other""#)
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(installedVersion(run.target), "0.2.0", "the previous app is back")
        XCTAssertEqual(try leftovers(nextTo: run.target), [])
        let logText = try String(contentsOfFile: run.log, encoding: .utf8)
        XCTAssertTrue(logText.contains("failed its signature check"))
        XCTAssertFalse(logText.contains("installed"))
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) {
        lock.withLock { stored.append(value) }
    }

    var values: [Double] {
        lock.withLock { stored }
    }
}
