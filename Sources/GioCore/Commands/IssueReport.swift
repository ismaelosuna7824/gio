import Foundation

/// DA-08: "Report a Problem" on the Diagnostics page. Gio saves a zip with
/// the logs and system facts and opens a prefilled GitHub issue; the user
/// drags the zip in and submits. No token, no server. Everything decided
/// here is pure; the adapter only copies, writes, zips and opens.

/// Browsers and GitHub accept far longer links, but proxies and some
/// handlers cut around 8 KB; stay safely under it.
public let issueReportMaxURLLength = 7000
/// How many `[WARN]`/`[ERROR]` lines the issue body quotes at most.
public let issueReportWarningLimit = 20
/// The default title is the description's first line, this long at most.
public let issueReportTitleLimit = 80

public struct IssueReportDisplay: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let scale: Double
    /// Hz; 0 when unknown (left out of the text).
    public let refreshRate: Int

    public init(width: Int, height: Int, scale: Double, refreshRate: Int) {
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshRate = refreshRate
    }

    var summary: String {
        let factor = scale == scale.rounded() ? String(Int(scale)) : String(format: "%.2g", scale)
        return "\(width)x\(height) @\(factor)x" + (refreshRate > 0 ? " \(refreshRate) Hz" : "")
    }
}

/// Facts for `system.txt` and the issue's System section. Never window
/// titles: the health lines come from the Diagnostics checklist.
public struct IssueReportSystem: Equatable, Sendable {
    public let version: String
    public let macOS: String
    public let architecture: String
    public let displays: [IssueReportDisplay]
    public let accessibilityTrusted: Bool
    public let healthLines: [String]

    public init(
        version: String, macOS: String, architecture: String, displays: [IssueReportDisplay],
        accessibilityTrusted: Bool, healthLines: [String]
    ) {
        self.version = version
        self.macOS = macOS
        self.architecture = architecture
        self.displays = displays
        self.accessibilityTrusted = accessibilityTrusted
        self.healthLines = healthLines
    }

    var displaySummary: String {
        displays.isEmpty ? "0" : "\(displays.count) (" + displays.map(\.summary).joined(separator: "; ") + ")"
    }
}

/// What the user typed plus the facts gathered when they pressed Create.
public struct IssueReportInput: Equatable, Sendable {
    public let title: String
    public let description: String
    public let includeConfig: Bool
    public let system: IssueReportSystem
    public let logPath: String
    public let configPath: String
    /// The current log file's text, for the recent warnings.
    public let logText: String
    public let date: Date

    public init(
        title: String, description: String, includeConfig: Bool, system: IssueReportSystem,
        logPath: String, configPath: String, logText: String, date: Date
    ) {
        self.title = title
        self.description = description
        self.includeConfig = includeConfig
        self.system = system
        self.logPath = logPath
        self.configPath = configPath
        self.logText = logText
        self.date = date
    }
}

/// A file copied into the report folder under `name`.
public struct IssueReportCopy: Equatable, Sendable {
    public let sourcePath: String
    public let name: String

    public init(sourcePath: String, name: String) {
        self.sourcePath = sourcePath
        self.name = name
    }
}

/// A text file written into the report folder.
public struct IssueReportText: Equatable, Sendable {
    public let name: String
    public let contents: String
}

public struct IssueReportPlan: Equatable, Sendable {
    /// `gio-report-yyyyMMdd-HHmmss`, the folder zipped with its parent kept.
    public let folderName: String
    public let copies: [IssueReportCopy]
    public let texts: [IssueReportText]
    public let issueURL: URL

    public var zipName: String { folderName + ".zip" }
}

private func capped(_ text: String, to limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
}

/// The description's first non-blank line, trimmed and capped.
public func issueReportDefaultTitle(description: String) -> String {
    let line = description.split(whereSeparator: \.isNewline)
        .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
    return capped(line, to: issueReportTitleLimit)
}

/// The typed title (trimmed) when there is one, else the default.
public func issueReportTitle(typed: String, description: String) -> String {
    let title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? issueReportDefaultTitle(description: description) : capped(title, to: 120)
}

public func issueReportFolderName(date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "gio-report-" + formatter.string(from: date)
}

/// The last `limit` lines Gio logged at warn or error, oldest first.
public func recentWarningLines(logText: String, limit: Int = issueReportWarningLimit) -> [String] {
    let lines = logText.split(whereSeparator: \.isNewline).map(String.init).filter { line in
        guard let entry = LogEntry.parse(line) else {
            return false
        }
        return entry.level >= .warn
    }
    return Array(lines.suffix(limit))
}

public func issueReportSystemText(_ system: IssueReportSystem) -> String {
    var lines = [
        "Gio: \(system.version)",
        "macOS: \(system.macOS)",
        "Architecture: \(system.architecture)",
        "Accessibility trusted: \(system.accessibilityTrusted ? "yes" : "no")",
        "Displays: \(system.displays.count)",
    ]
    lines += system.displays.enumerated().map { "  Display \($0.offset + 1): \($0.element.summary)" }
    if !system.healthLines.isEmpty {
        lines += ["", "Diagnostics:"] + system.healthLines.map { "  " + $0 }
    }
    return lines.joined(separator: "\n") + "\n"
}

public func issueReportDescriptionText(title: String, description: String) -> String {
    "Title: \(title)\n\n\(description)\n"
}

private let truncationNote = "… (truncated; the full text is in description.txt in the zip)"

/// The issue's markdown. `droppedWarnings`: older lines were left out to
/// fit the link; `truncatedDescription`: `description` is a prefix.
public func issueReportBody(
    description: String, system: IssueReportSystem, warnings: [String],
    droppedWarnings: Bool, truncatedDescription: Bool, zipName: String
) -> String {
    let what = truncatedDescription ? description + "\n\n" + truncationNote : description
    let recent: String
    if warnings.isEmpty {
        recent = droppedWarnings
            ? "Left out to fit the link; the lines are in the zip.\n"
            : "None in the current log.\n"
    } else {
        let note = droppedWarnings ? "The newest \(warnings.count); older lines are in the zip.\n\n" : ""
        recent = note + "```\n" + warnings.joined(separator: "\n") + "\n```\n"
    }
    return """
    ### What happened

    \(what)

    ### System

    - Gio: \(system.version)
    - macOS: \(system.macOS)
    - Architecture: \(system.architecture)
    - Accessibility trusted: \(system.accessibilityTrusted ? "yes" : "no")
    - Displays: \(system.displaySummary)

    ### Recent warnings

    \(recent)
    Logs: drag `\(zipName)` here.

    """
}

/// Unreserved characters only: `+`, `&`, `=`, `#`, `?` and non-ASCII are
/// all escaped (`URLQueryItem` leaves `+`, which GitHub reads as a space).
private let queryValueAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

/// `https://github.com/<repository>/issues/new?title=…&body=…&labels=bug`.
public func issueReportURL(repository: String, title: String, body: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/\(repository)/issues/new"
    func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
    components.percentEncodedQueryItems = [
        URLQueryItem(name: "title", value: encoded(title)),
        URLQueryItem(name: "body", value: encoded(body)),
        URLQueryItem(name: "labels", value: "bug"),
    ]
    return components.url!
}

/// The whole report: which files to copy (logs that exist; the config
/// only when asked), the texts to write, and the issue link capped at
/// `maxURLLength` by dropping the oldest warnings, then cutting the
/// description.
public func makeIssueReportPlan(
    _ input: IssueReportInput, fileExists: (String) -> Bool,
    repository: String = defaultUpdateRepository, maxURLLength: Int = issueReportMaxURLLength,
    timeZone: TimeZone = .current
) -> IssueReportPlan {
    let folderName = issueReportFolderName(date: input.date, timeZone: timeZone)
    let zipName = folderName + ".zip"
    let title = issueReportTitle(typed: input.title, description: input.description)

    var copies: [IssueReportCopy] = []
    for (path, name) in [(input.logPath, "gio.log"), (input.logPath + ".1", "gio.log.1")] where fileExists(path) {
        copies.append(IssueReportCopy(sourcePath: path, name: name))
    }
    if input.includeConfig, fileExists(input.configPath) {
        copies.append(IssueReportCopy(sourcePath: input.configPath, name: "config.toml"))
    }
    let texts = [
        IssueReportText(name: "system.txt", contents: issueReportSystemText(input.system)),
        IssueReportText(name: "description.txt", contents: issueReportDescriptionText(title: title, description: input.description)),
    ]

    let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let allWarnings = recentWarningLines(logText: input.logText)
    func link(_ text: String, truncated: Bool, warnings: ArraySlice<String>) -> URL {
        let body = issueReportBody(
            description: text, system: input.system, warnings: Array(warnings),
            droppedWarnings: warnings.count < allWarnings.count, truncatedDescription: truncated, zipName: zipName
        )
        return issueReportURL(repository: repository, title: title, body: body)
    }
    func fits(_ url: URL) -> Bool { url.absoluteString.count <= maxURLLength }

    var warnings = allWarnings[...]
    var url = link(description, truncated: false, warnings: warnings)
    while !fits(url), !warnings.isEmpty {
        warnings = warnings.dropFirst()
        url = link(description, truncated: false, warnings: warnings)
    }
    if !fits(url) {
        // Longest prefix that fits (binary search over characters).
        var low = 0
        var high = description.count
        var best = link("", truncated: true, warnings: warnings)
        while low <= high {
            let middle = (low + high) / 2
            let prefix = String(description.prefix(middle)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = link(prefix, truncated: true, warnings: warnings)
            if fits(candidate) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        url = best
    }
    return IssueReportPlan(folderName: folderName, copies: copies, texts: texts, issueURL: url)
}
