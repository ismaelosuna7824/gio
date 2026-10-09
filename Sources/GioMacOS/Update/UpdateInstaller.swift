import Darwin
import Foundation
import GioCore

/// UP-05: writes the helper script to a temp file and starts it with
/// `/usr/bin/nohup /bin/sh` in a new session (`POSIX_SPAWN_SETSID`), all
/// inherited descriptors closed, so it outlives Gio's exit. The helper checks
/// the swapped app against `requirement` again and rolls back (UP-12).
public struct DetachedScriptInstaller: UpdateInstalling {
    public static var defaultLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/Gio/update.log"
    }

    private let requirement: String?
    private let logPath: String
    private let ownPID: Int32

    /// `requirement` is the code requirement the preparer checked (nil when
    /// the running app has no team signature; installing then refuses).
    public init(
        requirement: String?, logPath: String = DetachedScriptInstaller.defaultLogPath, ownPID: Int32 = getpid()
    ) {
        self.requirement = requirement
        self.logPath = logPath
        self.ownPID = ownPID
    }

    public func install(stagedApp: String, target: String, waitPIDs: [Int32]) -> Result<Void, UpdateFailure> {
        guard let requirement else {
            return .failure(.installerFailed("no signing requirement"))
        }
        guard let stagingDirectory = updateStagingDirectory(ofStagedApp: stagedApp) else {
            return .failure(.installerFailed("unexpected staging location"))
        }
        let plan = UpdateInstallPlan(
            target: target, staged: stagedApp, stagingDirectory: stagingDirectory, requirement: requirement,
            waitPIDs: waitPIDs, logPath: logPath
        )
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gio-update-\(ownPID).sh")
        do {
            try updateInstallScript(plan).write(to: script, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.installerFailed("cannot write the helper script"))
        }
        let status = spawnDetached(["/usr/bin/nohup", "/bin/sh", script.path])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: script)
            return .failure(.installerFailed("spawn error \(status)"))
        }
        return .success(())
    }
}

/// posix_spawn in a new session with stdio on /dev/null; returns 0 or the errno.
func spawnDetached(_ argv: [String]) -> Int32 {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawnattr_destroy(&attributes)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer {
        posix_spawn_file_actions_destroy(&actions)
    }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var cArguments = argv.map { strdup($0) } + [nil]
    defer {
        cArguments.forEach { free($0) }
    }
    var pid: pid_t = 0
    return posix_spawn(&pid, argv[0], &actions, &attributes, &cArguments, environ)
}
