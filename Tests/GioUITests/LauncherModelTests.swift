import XCTest
@testable import GioUI

/// Plan §26: ranking, routing, app scanning over fixtures.
final class LauncherModelTests: XCTestCase {
    private let apps: [LauncherEntry] = [
        .app(name: "Code", bundleID: "com.microsoft.VSCode", path: "/Applications/Code.app"),
        .app(name: "Visual Studio", bundleID: nil, path: "/Applications/Visual Studio.app"),
        .app(name: "Chrome", bundleID: "com.google.Chrome", path: "/Applications/Chrome.app"),
    ]

    func testRankOrdersPrefixSubstringSubsequence() {
        XCTAssertEqual(rankMatch(query: "co", candidate: "Code"), 0)
        XCTAssertEqual(rankMatch(query: "od", candidate: "Code"), 1)
        XCTAssertEqual(rankMatch(query: "ce", candidate: "Code"), 2)
        XCTAssertNil(rankMatch(query: "zx", candidate: "Code"))
        XCTAssertNil(rankMatch(query: "", candidate: "Code"))
        XCTAssertEqual(rankMatch(query: "CHROME", candidate: "Chrome"), 0)
    }

    func testSearchSortsByRankThenName() {
        let results = searchLauncherEntries("co", in: apps)
        XCTAssertEqual(results.map(\.title), ["Code", "Chrome"])
        XCTAssertEqual(searchLauncherEntries("zzz", in: apps), [])
    }

    func testRouteGioCommands() {
        XCTAssertEqual(
            routeLauncherInput("> workspace 2", apps: apps),
            .runEntry(.gioCommand(argv: ["workspace", "2"], label: "workspace 2"))
        )
        XCTAssertEqual(
            routeLauncherInput("> reload", apps: apps),
            .runEntry(.gioCommand(argv: ["reload"], label: "reload"))
        )
        if case .invalid = routeLauncherInput("> frobnicate", apps: apps) {
        } else {
            XCTFail("expected invalid")
        }
    }

    func testRouteShellAndApps() {
        XCTAssertEqual(
            routeLauncherInput("!ls -la", apps: apps),
            .runEntry(.shellCommand("ls -la"))
        )
        XCTAssertEqual(
            routeLauncherInput("code", apps: apps),
            .runEntry(apps[0])
        )
        XCTAssertEqual(routeLauncherInput("zzz-no-app", apps: apps), .noMatch)
        XCTAssertEqual(routeLauncherInput("   ", apps: apps), .empty)
    }

    func testScanFindsBundlesOverFixtures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-launcher-test-\(UUID().uuidString)")
        let alpha = root.appendingPathComponent("Alpha.app/Contents").path
        let beta = root.appendingPathComponent("Beta.app").path
        try FileManager.default.createDirectory(atPath: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: beta, withIntermediateDirectories: true)
        let plist = (alpha as NSString).appendingPathComponent("Info.plist")
        let info = ["CFBundleIdentifier": "com.test.Alpha"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        FileManager.default.createFile(atPath: plist, contents: data)
        try "readme".write(
            toFile: (root.path as NSString).appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )
        let found = scanApplications(directories: [root.path]).apps
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].title, "Alpha")
        XCTAssertEqual(found[1].title, "Beta")
        if case .app(_, let bundleID, _) = found[0] {
            XCTAssertEqual(bundleID, "com.test.Alpha")
        } else {
            XCTFail("expected app entry")
        }
    }

    /// PA-14: every app launch rescans; only new or changed bundles are
    /// parsed again, removed ones drop out.
    func testRescanParsesOnlyNewOrChangedBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-launcher-rescan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ name: String, bundleID: String) throws {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Alpha", bundleID: "com.test.Alpha")
        try makeApp("Beta", bundleID: "com.test.Beta")
        try makeApp("Gamma", bundleID: "com.test.Gamma")
        var parsed: [String] = []
        func scan(_ previous: LauncherAppScan) -> LauncherAppScan {
            scanApplications(directories: [root.path], previous: previous) { path in
                parsed.append((path as NSString).lastPathComponent)
                return launcherBundleIdentifier(path)
            }
        }

        let first = scan(LauncherAppScan())
        XCTAssertEqual(parsed.sorted(), ["Alpha.app", "Beta.app", "Gamma.app"])

        parsed = []
        XCTAssertEqual(scan(first), first, "an unchanged rescan keeps every entry")
        XCTAssertEqual(parsed, [], "and parses nothing")

        try makeApp("Beta", bundleID: "com.test.Beta2")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: root.appendingPathComponent("Beta.app/Contents/Info.plist").path
        )
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gamma.app"))
        let second = scan(first)
        XCTAssertEqual(parsed, ["Beta.app"], "only the changed bundle")
        XCTAssertEqual(second.apps, [
            .app(name: "Alpha", bundleID: "com.test.Alpha", path: root.appendingPathComponent("Alpha.app").path),
            .app(name: "Beta", bundleID: "com.test.Beta2", path: root.appendingPathComponent("Beta.app").path),
        ])
        XCTAssertEqual(Set(second.stamps.keys), Set(second.apps.compactMap { entry -> String? in
            if case .app(_, _, let path) = entry { return path }
            return nil
        }), "the removed bundle drops out")
    }
}
