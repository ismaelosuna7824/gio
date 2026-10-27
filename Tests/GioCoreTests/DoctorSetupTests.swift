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

    /// The starter rule matches Calculator by bundle id: app names are
    /// localized ("Calculadora" on a Spanish system).
    func testTemplateStarterRuleMatchesCalculatorByBundleID() throws {
        let (config, _) = try parseGioConfig(defaultConfigTemplate()).get()
        let rule = try XCTUnwrap(config.rules.first)
        XCTAssertEqual(rule.bundleID, "com.apple.calculator")
        XCTAssertEqual(rule.app, "")
        XCTAssertEqual(rule.mode, .floating)
        XCTAssertTrue(rule.matches(app: "Calculadora", bundleID: "com.apple.calculator"))
    }

    func testTemplateDocumentsTheLauncherAction() {
        XCTAssertTrue(defaultConfigTemplate().contains("\"toggle-launcher\" (Alt+Space)"))
    }

    func testDoctorReportsFacts() {
        var session = CommandSession(
            permissionGranted: true, displayCount: 2, recentErrors: ["boom"]
        )
        let report = runDoctor(session: &session, ipcCheck: { "[ok] ipc: probed" })
        XCTAssertTrue(report.contains("[ok] accessibility: granted"))
        XCTAssertTrue(report.contains(gioVersion))
        XCTAssertTrue(report.contains("[ok] ipc: probed"))
        XCTAssertTrue(report.contains("displays: 2"))
        XCTAssertTrue(report.contains("recent errors: boom"))
    }

    /// PA-17a: the IPC line comes from the injected check, asked once.
    func testDoctorAsksTheIPCCheckOnce() {
        var calls = 0
        var session = CommandSession()
        let report = runDoctor(session: &session, ipcCheck: {
            calls += 1
            return "[fail] ipc: probed"
        })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(report.contains("[fail] ipc: probed"))
    }

    /// PA-17a: `gio doctor` reaches the session over its own sequential
    /// socket server, on the session queue; probing that socket from inside
    /// the request waited on itself forever. The in-session doctor reports
    /// IPC as serving (this very request) without connecting.
    func testInSessionDoctorDoesNotProbeItsOwnSocket() {
        var session = CommandSession(permissionGranted: true)
        let response = dispatchIPC(["doctor"], session: &session, restartAvailable: true)
        XCTAssertTrue(response.ok)
        let report = response.output ?? ""
        XCTAssertTrue(report.contains("[ok] ipc: serving this request"), report)
        XCTAssertFalse(report.contains("ipc: no session"), report)
        XCTAssertTrue(report.contains("[ok] accessibility: granted"), report)
    }

    func testDoctorUnknownsStayUnknown() {
        var session = CommandSession()
        let report = runDoctor(session: &session, ipcCheck: { "[ok] ipc: probed" })
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
