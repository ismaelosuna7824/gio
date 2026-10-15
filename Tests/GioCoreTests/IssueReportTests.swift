import Foundation
import XCTest
@testable import GioCore

/// DA-08: "Report a Problem" decisions: the bundle's contents, the texts it
/// holds, the recent-warning selection and the prefilled GitHub issue link.
final class IssueReportTests: XCTestCase {
    private let system = IssueReportSystem(
        version: "1.2.3", macOS: "Version 15.1 (Build 24B83)", architecture: "arm64",
        displays: [
            IssueReportDisplay(width: 1512, height: 982, scale: 2, refreshRate: 120),
            IssueReportDisplay(width: 2560, height: 1440, scale: 1, refreshRate: 0),
        ],
        accessibilityTrusted: true,
        healthLines: ["[ok] Permissions: Granted", "[warning] Configuration: 1 issue"]
    )

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func input(
        description: String = "Windows jump", title: String = "", includeConfig: Bool = false, logText: String = ""
    ) -> IssueReportInput {
        IssueReportInput(
            title: title, description: description, includeConfig: includeConfig, system: system,
            logPath: "/tmp/x/gio.log", configPath: "/tmp/x/config.toml", logText: logText,
            date: date("2026-10-15T08:09:10Z")
        )
    }

    // MARK: - Title

    func testDefaultTitleIsTheTrimmedFirstLine() {
        XCTAssertEqual(issueReportDefaultTitle(description: "\n  Windows jump left  \nmore text"), "Windows jump left")
        XCTAssertEqual(issueReportDefaultTitle(description: "   \n"), "")
    }

    func testDefaultTitleIsCappedWithAnEllipsis() {
        let title = issueReportDefaultTitle(description: String(repeating: "a", count: 200))
        XCTAssertEqual(title.count, 80)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testTypedTitleWinsOverTheDefault() {
        XCTAssertEqual(issueReportTitle(typed: "  Crash on wake ", description: "Windows jump"), "Crash on wake")
        XCTAssertEqual(issueReportTitle(typed: " ", description: "Windows jump\nmore"), "Windows jump")
    }

    // MARK: - Names and files

    func testFileNameUsesTheLocalTimestamp() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            issueReportFolderName(date: date("2026-10-15T08:09:10Z"), timeZone: utc), "gio-report-20261015-080910"
        )
    }

    func testPlanCopiesOnlyLogsThatExistAndNoConfigByDefault() {
        let existing: Set = ["/tmp/x/gio.log", "/tmp/x/config.toml"]
        let plan = makeIssueReportPlan(input(), fileExists: { existing.contains($0) }, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(plan.folderName, "gio-report-20261015-080910")
        XCTAssertEqual(plan.zipName, "gio-report-20261015-080910.zip")
        XCTAssertEqual(plan.copies, [IssueReportCopy(sourcePath: "/tmp/x/gio.log", name: "gio.log")])
        XCTAssertEqual(plan.texts.map(\.name), ["system.txt", "description.txt"])
    }

    func testPlanCopiesTheRotatedLogAndTheConfigWhenAsked() {
        let existing: Set = ["/tmp/x/gio.log", "/tmp/x/gio.log.1", "/tmp/x/config.toml"]
        let plan = makeIssueReportPlan(
            input(includeConfig: true), fileExists: { existing.contains($0) }, timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(plan.copies.map(\.name), ["gio.log", "gio.log.1", "config.toml"])
        XCTAssertEqual(plan.copies.map(\.sourcePath), ["/tmp/x/gio.log", "/tmp/x/gio.log.1", "/tmp/x/config.toml"])
    }

    func testPlanSkipsAMissingConfigEvenWhenAsked() {
        let plan = makeIssueReportPlan(input(includeConfig: true), fileExists: { $0 == "/tmp/x/gio.log" })
        XCTAssertEqual(plan.copies.map(\.name), ["gio.log"])
    }

    // MARK: - Texts

    func testSystemTextListsEveryFact() {
        let text = issueReportSystemText(system)
        XCTAssertTrue(text.contains("Gio: 1.2.3"))
        XCTAssertTrue(text.contains("macOS: Version 15.1 (Build 24B83)"))
        XCTAssertTrue(text.contains("Architecture: arm64"))
        XCTAssertTrue(text.contains("Accessibility trusted: yes"))
        XCTAssertTrue(text.contains("Displays: 2"))
        XCTAssertTrue(text.contains("1512x982 @2x 120 Hz"))
        XCTAssertTrue(text.contains("2560x1440 @1x"))
        XCTAssertFalse(text.contains("@1x 0 Hz"))
        XCTAssertTrue(text.contains("[warning] Configuration: 1 issue"))
    }

    func testDescriptionTextKeepsTitleAndTextAsTyped() {
        XCTAssertEqual(
            issueReportDescriptionText(title: "Crash", description: "line 1\nline 2"), "Title: Crash\n\nline 1\nline 2\n"
        )
    }

    // MARK: - Recent warnings

    func testRecentWarningsKeepTheLastWarnAndErrorLines() {
        var lines: [String] = []
        for index in 0..<30 {
            lines.append("[2026-10-15T08:00:\(index)] [INFO] tick \(index)")
            lines.append("[2026-10-15T08:00:\(index)] [\(index.isMultiple(of: 2) ? "WARN" : "ERROR")] bad \(index)")
        }
        lines.append("garbage [WARN] not a log line")
        let warnings = recentWarningLines(logText: lines.joined(separator: "\n"), limit: 20)
        XCTAssertEqual(warnings.count, 20)
        XCTAssertEqual(warnings.first, "[2026-10-15T08:00:10] [WARN] bad 10")
        XCTAssertEqual(warnings.last, "[2026-10-15T08:00:29] [ERROR] bad 29")
    }

    // MARK: - Issue link

    func testURLTargetsTheRepositoryWithTitleBodyAndBugLabel() {
        let plan = makeIssueReportPlan(input(), fileExists: { _ in false }, timeZone: TimeZone(identifier: "UTC")!)
        let components = URLComponents(url: plan.issueURL, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/\(defaultUpdateRepository)/issues/new")
        let values = query(plan.issueURL)
        XCTAssertEqual(values["title"], "Windows jump")
        XCTAssertEqual(values["labels"], "bug")
        let body = values["body"] ?? ""
        XCTAssertTrue(body.hasPrefix("### What happened\n\nWindows jump\n"))
        XCTAssertTrue(body.contains("### System"))
        XCTAssertTrue(body.contains("- Gio: 1.2.3"))
        XCTAssertTrue(body.contains("- Displays: 2 (1512x982 @2x 120 Hz; 2560x1440 @1x)"))
        XCTAssertTrue(body.contains("### Recent warnings"))
        XCTAssertTrue(body.hasSuffix("Logs: drag `gio-report-20261015-080910.zip` here.\n"))
    }

    func testBodyFencesTheWarnings() {
        let body = issueReportBody(
            description: "x", system: system,
            warnings: ["[t] [WARN] one", "[t] [ERROR] two"], droppedWarnings: false, truncatedDescription: false,
            zipName: "r.zip"
        )
        XCTAssertTrue(body.contains("### Recent warnings\n\n```\n[t] [WARN] one\n[t] [ERROR] two\n```\n"))
    }

    func testBodySaysWhenThereAreNoWarnings() {
        let body = issueReportBody(
            description: "x", system: system, warnings: [], droppedWarnings: false, truncatedDescription: false,
            zipName: "r.zip"
        )
        XCTAssertTrue(body.contains("### Recent warnings\n\nNone in the current log.\n"))
    }

    func testSpecialCharactersSurviveARoundTrip() {
        let description = "a & b = c # d + e? 100% /path\nsecond line ñandú 日本語 🙂"
        let plan = makeIssueReportPlan(
            input(description: description, title: "T&T #1 + más"), fileExists: { _ in false }
        )
        let values = query(plan.issueURL)
        XCTAssertEqual(values["title"], "T&T #1 + más")
        XCTAssertTrue(values["body"]?.contains("### What happened\n\n\(description)\n") ?? false)
        let query = plan.issueURL.query ?? ""
        XCTAssertFalse(query.contains("+"), "a literal + would read as a space")
        XCTAssertFalse(query.contains("#"))
        XCTAssertNil(plan.issueURL.fragment)
    }

    func testLongWarningsDropOldestFirstToFitTheCap() {
        let lines = (0..<20).map { "[2026-10-15T08:00:00] [WARN] \(String(repeating: "w", count: 300)) \($0)" }
        let plan = makeIssueReportPlan(
            input(logText: lines.joined(separator: "\n")), fileExists: { _ in false }, maxURLLength: 4000
        )
        XCTAssertLessThanOrEqual(plan.issueURL.absoluteString.count, 4000)
        let body = query(plan.issueURL)["body"] ?? ""
        XCTAssertTrue(body.contains(" 19\n"), "the newest warning stays")
        XCTAssertFalse(body.contains(" 0\n"), "the oldest warning goes first")
        XCTAssertTrue(body.contains("Windows jump"))
        XCTAssertTrue(body.contains("older lines are in the zip"))
    }

    func testLongDescriptionIsTruncatedWithANoteAfterTheWarningsAreGone() {
        let lines = (0..<5).map { "[2026-10-15T08:00:00] [WARN] warning \($0)" }
        let description = String(repeating: "día ", count: 3000)
        let plan = makeIssueReportPlan(
            input(description: description, logText: lines.joined(separator: "\n")), fileExists: { _ in false }
        )
        XCTAssertLessThanOrEqual(plan.issueURL.absoluteString.count, issueReportMaxURLLength)
        XCTAssertGreaterThan(plan.issueURL.absoluteString.count, issueReportMaxURLLength - 200, "uses the room it has")
        let body = query(plan.issueURL)["body"] ?? ""
        XCTAssertFalse(body.contains("warning 4"))
        XCTAssertTrue(body.contains("… (truncated; the full text is in description.txt in the zip)"))
        XCTAssertTrue(body.contains("### System"))
        XCTAssertTrue(body.hasSuffix("here.\n"))
        let full = plan.texts.first { $0.name == "description.txt" }?.contents ?? ""
        XCTAssertTrue(full.contains(description), "the zip keeps the whole description")
    }

    func testShortReportIsNotTouched() {
        let lines = ["[2026-10-15T08:00:00] [ERROR] boom"]
        let plan = makeIssueReportPlan(input(logText: lines.joined(separator: "\n")), fileExists: { _ in false })
        let body = query(plan.issueURL)["body"] ?? ""
        XCTAssertTrue(body.contains("```\n[2026-10-15T08:00:00] [ERROR] boom\n```"))
        XCTAssertFalse(body.contains("truncated"))
        XCTAssertFalse(body.contains("older lines"))
    }
}
