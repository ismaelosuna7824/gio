import Foundation
import GioCore

/// DA-08: carry out an `IssueReportPlan`. The folder is staged in a temp
/// directory, zipped with `ditto` (parent kept, so it unpacks as a folder)
/// into `directory`, then removed. Blocking: never on the main thread.
public enum IssueReportBundleError: LocalizedError, Equatable {
    case missingDestination(String)
    case zipFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .missingDestination(let path): return "The folder \(path) does not exist."
        case .zipFailed(let status): return "Could not create the zip (ditto status \(status))."
        }
    }
}

/// Returns the zip's URL (`directory/<plan.zipName>`, replacing one of the
/// same name).
public func writeIssueReportBundle(_ plan: IssueReportPlan, in directory: URL) throws -> URL {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw IssueReportBundleError.missingDestination(directory.path)
    }
    let staging = fm.temporaryDirectory.appendingPathComponent("gio-report-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }
    let folder = staging.appendingPathComponent(plan.folderName)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for copy in plan.copies {
        try fm.copyItem(atPath: copy.sourcePath, toPath: folder.appendingPathComponent(copy.name).path)
    }
    for text in plan.texts {
        try text.contents.write(to: folder.appendingPathComponent(text.name), atomically: true, encoding: .utf8)
    }
    let zip = directory.appendingPathComponent(plan.zipName)
    try? fm.removeItem(at: zip)
    let status = runUpdateTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
    guard status == 0 else {
        try? fm.removeItem(at: zip)
        throw IssueReportBundleError.zipFailed(status)
    }
    return zip
}

/// Each screen's size in points, scale and refresh rate, in position
/// order. AppKit state: call on the main thread.
public func currentIssueReportDisplays() -> [IssueReportDisplay] {
    snapshotDisplayList().map {
        IssueReportDisplay(
            width: Int($0.frame.width), height: Int($0.frame.height),
            scale: Double($0.scale), refreshRate: $0.refreshRate
        )
    }
}

/// The architecture this process runs as.
public var currentProcessArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
