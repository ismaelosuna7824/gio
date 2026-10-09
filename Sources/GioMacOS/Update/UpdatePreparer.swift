import Foundation
import GioCore

/// UP-08: download → checksum → image signature (UP-16) → mount → app
/// signature → bundle check → copy into a fresh private folder next to the
/// installed app (UP-12) without ACLs, extended attributes or quarantine,
/// normalised permissions (UP-14) → signature of the staged copy. Every
/// refusal leaves nothing staged and the image detached. Logs carry
/// versions and reasons only.
public final class UpdatePreparer: UpdatePreparing, @unchecked Sendable {
    private let downloader: UpdateAssetDownloading
    private let mounter: DiskImageMounting
    /// Nil when the running app has no team signature to compare against.
    private let verifier: @Sendable () -> CodeSignatureVerifying?
    private let bundleIdentifier: String
    private let workRoot: URL
    private let log: @Sendable (LogLevel, String) -> Void

    public init(
        downloader: UpdateAssetDownloading, mounter: DiskImageMounting = HdiutilMounter(),
        verifier: @escaping @Sendable () -> CodeSignatureVerifying?, bundleIdentifier: String,
        workRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("gio-update"),
        log: @escaping @Sendable (LogLevel, String) -> Void = { _, _ in }
    ) {
        self.downloader = downloader
        self.mounter = mounter
        self.verifier = verifier
        self.bundleIdentifier = bundleIdentifier
        self.workRoot = workRoot
        self.log = log
    }

    public func prepare(
        _ update: AvailableUpdate, target: String, progress: @escaping @Sendable (Double) -> Void,
        verifying: @escaping @Sendable () -> Void
    ) async -> Result<String, UpdateFailure> {
        let result = await run(update, target: target, progress: progress, verifying: verifying)
        switch result {
        case .success:
            log(.info, "update \(update.version) verified and staged")
        case .failure(let failure):
            log(.warn, "update \(update.version) refused: \(failure)")
        }
        return result
    }

    private func run(
        _ update: AvailableUpdate, target: String, progress: @escaping @Sendable (Double) -> Void,
        verifying: @escaping @Sendable () -> Void
    ) async -> Result<String, UpdateFailure> {
        guard let verifier = verifier() else {
            return .failure(.notEligible(.unsignedBuild))
        }
        let work = workRoot.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failure(.stagingFailed("cannot create a temporary folder"))
        }
        defer {
            try? FileManager.default.removeItem(at: work)
        }
        let expected: String
        let image: URL
        do {
            let sumFile = try await downloader.download(update.checksum, to: work, progress: { _ in })
            guard let text = try? String(contentsOf: sumFile, encoding: .utf8),
                  let digest = parseChecksumFile(text, expectedFileName: update.dmg.name) else {
                return .failure(.checksumUnreadable)
            }
            expected = digest
            image = try await downloader.download(update.dmg, to: work, progress: progress)
        } catch let failure as UpdateFailure {
            return .failure(failure)
        } catch {
            return .failure(.downloadFailed("transfer failed"))
        }
        verifying()
        guard let actual = try? sha256Hex(ofFileAt: image), actual == expected else {
            return .failure(.checksumMismatch)
        }
        if case .failure(let failure) = verifier.verify(imageAt: image) {
            return .failure(failure)
        }
        let mountPoint = work.appendingPathComponent("mount")
        do {
            try mounter.attach(image, at: mountPoint)
        } catch let failure as UpdateFailure {
            return .failure(failure)
        } catch {
            return .failure(.mountFailed("attach failed"))
        }
        defer {
            mounter.detach(mountPoint)
        }
        let app = mountPoint.appendingPathComponent("Gio.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            return .failure(.appMissing)
        }
        if case .failure(let failure) = verifier.verify(appAt: app) {
            return .failure(failure)
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        if let mismatch = checkUpdateBundle(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            expectedBundleIdentifier: bundleIdentifier, expectedVersion: update.version
        ) {
            return .failure(mismatch)
        }
        guard let folder = makeUpdateStagingDirectory(target: target) else {
            return .failure(.stagingFailed("cannot create a private staging folder"))
        }
        let staged = (folder as NSString).appendingPathComponent("Gio.app")
        let refusal: UpdateFailure?
        if runUpdateTool("/usr/bin/ditto", ["--noacl", "--noextattr", "--noqtn", app.path, staged]) != 0 {
            refusal = .stagingFailed("copy next to the installed app failed")
        } else if let unsafe = normaliseStagedTree(at: staged) {
            refusal = .stagingFailed("the new app contains \(unsafe)")
        } else if case .failure(let failure) = verifier.verify(appAt: URL(fileURLWithPath: staged)) {
            refusal = failure
        } else {
            refusal = nil
        }
        if let refusal {
            if (try? FileManager.default.removeItem(atPath: folder)) == nil {
                log(.warn, "update \(update.version): could not remove the staging folder")
            }
            return .failure(refusal)
        }
        return .success(staged)
    }
}

/// `mkdtemp` of `updateStagingTemplate(target:)`: a new 0700 folder that did
/// not exist before, or nil (UP-12).
public func makeUpdateStagingDirectory(target: String) -> String? {
    var template = Array(updateStagingTemplate(target: target).utf8CString)
    return template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else {
            return nil
        }
        return String(cString: base)
    }
}

/// Applies `stagedEntryDecision` to every item under `root` (the root too),
/// without following symlinks, and removes every ACL (`ditto --noacl` keeps
/// file ACLs: observed on APFS, UP-14). Returns the refusal reason, or nil
/// when the tree is now normalised.
func normaliseStagedTree(at root: String) -> String? {
    let user = getuid()
    var paths = [root]
    if let enumerator = FileManager.default.enumerator(atPath: root) {
        while let relative = enumerator.nextObject() as? String {
            paths.append((root as NSString).appendingPathComponent(relative))
        }
    }
    for path in paths {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return "an unreadable item"
        }
        let kind: StagedEntryKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        case S_IFREG: kind = .file
        default: return "a special file"
        }
        switch stagedEntryDecision(mode: info.st_mode, owner: info.st_uid, currentUser: user, kind: kind) {
        case .keep:
            break
        case .setMode(let mode):
            guard chmod(path, mode) == 0 else {
                return "an item whose permissions cannot be fixed"
            }
        case .refuse(let reason):
            return reason
        }
        if kind != .symlink, !removeACL(path) {
            return "an item whose access list cannot be removed"
        }
    }
    return nil
}

/// Replaces the item's extended ACL with an empty one.
private func removeACL(_ path: String) -> Bool {
    guard let empty = acl_init(0) else {
        return false
    }
    defer {
        acl_free(UnsafeMutableRawPointer(empty))
    }
    return acl_set_file(path, ACL_TYPE_EXTENDED, empty) == 0
}
