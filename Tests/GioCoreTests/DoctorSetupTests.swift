import XCTest
@testable import GioCore

/// Plan §28: doctor diagnoses, setup guides and installs, update/uninstall
/// stay honest pre-1.0. The template parses back clean.
final class DoctorSetupTests: XCTestCase {
    func testTemplateParsesClean() throws {
        let (config, warnings) = try parseGioConfig(defaultConfigTemplate()).get()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.layout.gaps, 8)
        XCTAssertEqual(config.rules.count, 1)
    }

    func testDoctorReportsFacts() {
        var session = CommandSession(
            permissionGranted: true, displayCount: 2, recentErrors: ["boom"]
        )
        let report = runDoctor(session: &session)
        XCTAssertTrue(report.contains("[ok] accessibility: granted"))
        XCTAssertTrue(report.contains(gioVersion))
        // IPC line depends on the environment (a live daemon answers,
        // otherwise it reports no session) — either is honest.
        XCTAssertTrue(report.contains("ipc:"))
        XCTAssertTrue(report.contains("displays: 2"))
        XCTAssertTrue(report.contains("recent errors: boom"))
    }

    func testDoctorUnknownsStayUnknown() {
        var session = CommandSession()
        let report = runDoctor(session: &session)
        XCTAssertTrue(report.contains("[??] accessibility: unknown"))
        XCTAssertTrue(report.contains("[??] displays: unknown"))
        XCTAssertTrue(report.contains("recent errors: none"))
    }

    func testSetupInstallsTemplateOnce() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gio-setup-test-\(UUID().uuidString)").path
        let path = (dir as NSString).appendingPathComponent("config.toml")
        var session = CommandSession(permissionGranted: true, configPath: path)
        let first = runSetup(session: &session)
        XCTAssertTrue(first.contains("template written"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(first.contains("hotkeys:"))
        XCTAssertTrue(first.contains("themes: builtin"))
        XCTAssertTrue(first.contains("autostart: not installed"))
        let second = runSetup(session: &session)
        XCTAssertFalse(second.contains("template written"))
        XCTAssertTrue(second.contains(path))
    }

    func testUpdateAndUninstallMessages() {
        XCTAssertTrue(runUpdate().contains(gioVersion))
        XCTAssertTrue(runUpdate().contains("open the Gio app"))
        XCTAssertTrue(runUpdate(install: true).contains("cannot install"))
        let out = runUninstall()
        // Either branch keeps user data; a running session refuses instead.
        XCTAssertTrue(out.contains("kept:"))
    }

    func testDispatchNewVerbs() {
        var session = CommandSession()
        XCTAssertTrue(dispatch(.doctor, session: &session).contains("Gio doctor"))
        XCTAssertTrue(dispatch(.update(install: false), session: &session).contains(gioVersion))
        XCTAssertTrue(dispatch(.uninstall, session: &session).contains("kept:"))
        XCTAssertEqual(try parseCLICommand(["doctor"]).get(), .doctor)
        XCTAssertEqual(try parseCLICommand(["setup"]).get(), .setup)
        XCTAssertEqual(try parseCLICommand(["update"]).get(), .update(install: false))
        XCTAssertEqual(try parseCLICommand(["update", "--install"]).get(), .update(install: true))
        XCTAssertEqual(
            parseCLICommand(["update", "now"]), .failure(.missingArgument(name: "--install", command: "update"))
        )
        XCTAssertEqual(try parseCLICommand(["uninstall"]).get(), .uninstall)
        XCTAssertTrue(cliUsage().contains("gio doctor"))
    }
}
