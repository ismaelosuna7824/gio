import Foundation
import GioCore

/// UP-08: attach a disk image read-only at a private mount point (never in
/// Finder's sidebar) and detach it again.
public protocol DiskImageMounting: Sendable {
    func attach(_ image: URL, at mountPoint: URL) throws
    func detach(_ mountPoint: URL)
}

public struct HdiutilMounter: DiskImageMounting {
    public init() {}

    public func attach(_ image: URL, at mountPoint: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let status = runUpdateTool(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, image.path]
        )
        guard status == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw UpdateFailure.mountFailed("hdiutil status \(status)")
        }
    }

    public func detach(_ mountPoint: URL) {
        if runUpdateTool("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path]) != 0 {
            _ = runUpdateTool("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
        }
        try? FileManager.default.removeItem(at: mountPoint)
    }
}

/// Runs a system tool to completion with its output discarded; the exit
/// status, or -1 when it could not start. Blocking: never on the main thread.
@discardableResult
func runUpdateTool(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
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
