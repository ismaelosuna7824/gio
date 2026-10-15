import AppKit
import GioCore
import GioMacOS

/// DA-08: what the Report a Problem card hands to `createIssueReport`.
struct IssueReportRequest: Equatable, Sendable {
    var title: String
    var description: String
    var includeConfig: Bool
    var configPath: String
    /// The Diagnostics checklist, as `issueReportHealthLines` renders it.
    var healthLines: [String]
}

/// Gathers the system facts, writes the zip into `directory` off the main
/// thread, then shows it in Finder and opens the prefilled GitHub issue.
/// The completion gets the zip, or the error to show.
@MainActor
func createIssueReport(
    _ request: IssueReportRequest, in directory: URL = issueReportDestination(),
    completion: @escaping @MainActor (Result<URL, Error>) -> Void
) {
    let system = IssueReportSystem(
        version: gioVersion, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: currentProcessArchitecture, displays: currentIssueReportDisplays(),
        accessibilityTrusted: hasAXPermission(), healthLines: request.healthLines
    )
    let logPath = GioLog.logFilePath
    let date = Date()
    Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL, URL), Error> in
            GioLog.flush()
            let input = IssueReportInput(
                title: request.title, description: request.description, includeConfig: request.includeConfig,
                system: system, logPath: logPath, configPath: request.configPath,
                logText: (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "", date: date
            )
            let plan = makeIssueReportPlan(input, fileExists: { FileManager.default.fileExists(atPath: $0) })
            return Result {
                let zip = try writeIssueReportBundle(plan, in: directory)
                GioLog.record(
                    .info,
                    "issue report saved name=\(plan.zipName) files=\(plan.copies.count + plan.texts.count) "
                        + "config=\(request.includeConfig) linkChars=\(plan.issueURL.absoluteString.count)"
                )
                return (zip, plan.issueURL)
            }
        }.value
        switch result {
        case .success(let (zip, issue)):
            NSWorkspace.shared.activateFileViewerSelecting([zip])
            NSWorkspace.shared.open(issue)
            completion(.success(zip))
        case .failure(let error):
            GioLog.record(.warn, "issue report failed error=\(error.localizedDescription)")
            completion(.failure(error))
        }
    }
}

/// `~/Downloads`.
func issueReportDestination() -> URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
}
