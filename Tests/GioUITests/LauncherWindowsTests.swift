import GioCore
import XCTest
@testable import GioUI

/// HD-06: the launcher searches managed windows next to apps.
final class LauncherWindowsTests: XCTestCase {
    private func fact(
        _ id: String, _ app: String, _ title: String, workspace: Int? = 1, minimized: Bool = false
    ) -> WindowFact {
        WindowFact(
            id: id, application: app, title: title, workspace: workspace, mode: .tiled,
            floatReason: nil, isMinimized: minimized, workspaceIsShown: true
        )
    }

    private let apps: [LauncherEntry] = [
        .app(name: "Code", bundleID: nil, path: "/Applications/Code.app"),
        .app(name: "Chrome", bundleID: nil, path: "/Applications/Chrome.app"),
    ]

    func testWindowEntriesSkipMinimizedAndSortByAppThenTitle() {
        let entries = launcherWindowEntries(from: [
            fact("2:1", "Safari", "Zebra"),
            fact("1:1", "Code", "main.swift"),
            fact("2:2", "Safari", "Apple", workspace: 3),
            fact("3:1", "Mail", "Inbox", minimized: true),
        ])
        XCTAssertEqual(entries.map(\.title), ["Code — main.swift", "Safari — Apple", "Safari — Zebra"])
        XCTAssertEqual(entries[1], .window(id: "2:2", application: "Safari", windowTitle: "Apple", workspace: 3))
    }

    func testUntitledWindowShowsJustTheApp() {
        let entries = launcherWindowEntries(from: [fact("1:1", "Terminal", "")])
        XCTAssertEqual(entries.map(\.title), ["Terminal"])
    }

    func testWindowMatchesByAppNameOrTitle() {
        let windows = launcherWindowEntries(from: [fact("2:1", "Safari", "Inbox (Gmail)")])
        XCTAssertEqual(searchLauncherEntries("gmail", in: windows), windows)
        XCTAssertEqual(searchLauncherEntries("safari", in: windows), windows)
        XCTAssertEqual(searchLauncherEntries("zzz", in: windows), [])
    }

    func testWindowOutranksTheAppOnAnEqualMatch() {
        let windows = launcherWindowEntries(from: [fact("1:1", "Code", "main.swift")])
        let results = searchLauncherEntries("code", in: apps + windows)
        XCTAssertEqual(results.map(\.title), ["Code — main.swift", "Code"])
    }

    func testATitleOnlyMatchDoesNotBeatAnAppNameMatch() {
        let windows = launcherWindowEntries(from: [fact("2:1", "Safari", "Chrome extensions")])
        let results = searchLauncherEntries("chr", in: windows + apps)
        XCTAssertEqual(results.map(\.title), ["Chrome", "Safari — Chrome extensions"])
    }

    func testRankingStaysDeterministicAcrossKindsAndTitles() {
        let windows = launcherWindowEntries(from: [
            fact("1:2", "Code", "b.swift"), fact("1:1", "Code", "a.swift"),
        ])
        let first = searchLauncherEntries("code", in: apps + windows)
        let second = searchLauncherEntries("code", in: (apps + windows).reversed())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.title), ["Code — a.swift", "Code — b.swift", "Code"])
    }

    func testRoutingOpensTheBestWindow() {
        let windows = launcherWindowEntries(from: [fact("2:1", "Safari", "Inbox (Gmail)")])
        XCTAssertEqual(routeLauncherInput("gmail", apps: apps + windows), .runEntry(windows[0]))
    }

    func testEntriesCarryADistinctKindLabelAndIcon() {
        let window = launcherWindowEntries(from: [fact("2:1", "Safari", "Inbox", workspace: 4)])[0]
        XCTAssertEqual(window.kindLabel, "Window · workspace 4")
        XCTAssertEqual(apps[0].kindLabel, "App")
        XCTAssertNotEqual(window.symbol, apps[0].symbol)
    }
}
