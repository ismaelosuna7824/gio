import XCTest
@testable import GioUI

/// NW-03 app picker sources: `.app` bundles scanned from a fixture
/// directory (never the real /Applications), merged with running apps.
final class InstalledAppsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gio-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ path: String, plist: [String: String]) throws {
        let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testScanReadsBundlesOneFolderDeepAndSkipsTheRest() throws {
        try makeApp("Visual Studio Code.app", plist: ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleName": "Code"])
        try makeApp("Utilities/Console.app", plist: [
            "CFBundleIdentifier": "com.apple.Console", "CFBundleName": "Console", "CFBundleDisplayName": "Console",
        ])
        try makeApp("Nameless.app", plist: ["CFBundleIdentifier": "org.example.nameless"])
        try makeApp("NoIdentifier.app", plist: ["CFBundleName": "Broken"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try makeApp("Deep/Nested/Too Deep.app", plist: ["CFBundleIdentifier": "org.example.deep"])

        let apps = scanInstalledApps(in: [root])
        XCTAssertEqual(apps.map(\.name), ["Code", "Console", "Nameless"])
        XCTAssertEqual(apps.map(\.bundleID), ["com.microsoft.VSCode", "com.apple.Console", "org.example.nameless"])
        XCTAssertTrue(apps.allSatisfy { !$0.isRunning })
        XCTAssertEqual(apps.first?.path.map { URL(fileURLWithPath: $0).lastPathComponent }, "Visual Studio Code.app")
    }

    func testDuplicatesAcrossDirectoriesKeepTheFirst() throws {
        let other = root.appendingPathComponent("home")
        try makeApp("Safari.app", plist: ["CFBundleIdentifier": "com.apple.Safari", "CFBundleName": "Safari"])
        try makeApp("home/Safari Copy.app", plist: ["CFBundleIdentifier": "com.apple.Safari", "CFBundleName": "Safari Copy"])
        let apps = scanInstalledApps(in: [root, other, root.appendingPathComponent("missing")])
        XCTAssertEqual(apps.map(\.name), ["Safari"])
    }

    func testMergePutsRunningAppsFirstAndDedupes() {
        let running = [
            AppCandidate(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", isRunning: true),
            AppCandidate(name: "Safari", bundleID: "com.apple.Safari", isRunning: true),
        ]
        let installed = [
            AppCandidate(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
            AppCandidate(name: "Notes", bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app"),
        ]
        let merged = mergeAppCandidates(running: running, installed: installed)
        XCTAssertEqual(merged.map(\.name), ["Safari", "Slack", "Notes"])
        XCTAssertEqual(merged.map(\.isRunning), [true, true, false])
        XCTAssertEqual(merged.first?.path, "/Applications/Safari.app", "running entry picks up the path")
    }

    func testFilterMatchesNameOrBundleID() {
        let apps = [
            AppCandidate(name: "Safari", bundleID: "com.apple.Safari"),
            AppCandidate(name: "Code", bundleID: "com.microsoft.VSCode"),
        ]
        XCTAssertEqual(filterAppCandidates(apps, query: "").count, 2)
        XCTAssertEqual(filterAppCandidates(apps, query: "saf").map(\.name), ["Safari"])
        XCTAssertEqual(filterAppCandidates(apps, query: "microsoft").map(\.name), ["Code"])
        XCTAssertEqual(filterAppCandidates(apps, query: "  CODE ").map(\.name), ["Code"])
    }

    func testDefaultDirectories() {
        XCTAssertEqual(
            installedAppDirectories(home: "/Users/me").map(\.path),
            ["/Applications", "/System/Applications", "/Users/me/Applications"]
        )
    }

    func testCandidateBecomesAnAssignment() {
        let assignment = AppCandidate(name: "Safari", bundleID: "com.apple.Safari").assignment
        XCTAssertEqual(assignment, WorkspaceAppAssignment(app: "Safari", bundleID: "com.apple.Safari"))
    }
}
