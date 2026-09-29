import XCTest
@testable import GioCore

final class WindowReconcileDecisionTests: XCTestCase {
    private func id(_ element: UInt64, pid: pid_t = 10) -> WindowID {
        WindowID(pid: pid, elementID: element)
    }

    private func window(
        _ element: UInt64, app: String = "App", pid: pid_t = 10,
        mode: WindowMode = .tiled, reason: FloatReason? = nil, minimized: Bool = false
    ) -> ManagedWindow {
        ManagedWindow(
            id: id(element, pid: pid), pid: pid, application: app, title: "t",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), mode: mode,
            floatReason: reason, isMinimized: minimized
        )
    }

    // MARK: Rules on reload

    func testNewlyMatchingFloatRuleFloatsTiledWindow() {
        let rules = [WindowRule(app: "App", mode: .floating)]
        XCTAssertEqual(reevaluateRules(rules, windows: [window(1)]), [.float(id(1))])
    }

    func testRuleFloatNoLongerMatchingReturnsToTiled() {
        let windows = [window(1, mode: .floating, reason: .rule)]
        XCTAssertEqual(reevaluateRules([], windows: windows), [.tile(id(1))])
    }

    func testStillMatchingRuleFloatIsUntouched() {
        let rules = [WindowRule(app: "App", mode: .floating)]
        let windows = [window(1, mode: .floating, reason: .rule)]
        XCTAssertEqual(reevaluateRules(rules, windows: windows), [])
    }

    func testAdmissionAndManualFloatsAreNeverPromoted() {
        let windows = [
            window(1, mode: .floating, reason: .notResizable),
            window(2, mode: .floating, reason: .dialog),
            window(3, mode: .floating, reason: .floatingSubrole),
            window(4, mode: .floating, reason: .manual),
        ]
        XCTAssertEqual(reevaluateRules([], windows: windows), [])
    }

    func testAdmissionFloatsKeepTheirReasonWhenARuleAlsoMatches() {
        let rules = [WindowRule(app: "App", mode: .floating)]
        let windows = [window(1, mode: .floating, reason: .notResizable)]
        XCTAssertEqual(reevaluateRules(rules, windows: windows), [])
    }

    func testRuleForcingTiledReleasesRuleFloat() {
        let rules = [WindowRule(app: "App", mode: .tiled)]
        let windows = [window(1, mode: .floating, reason: .rule)]
        XCTAssertEqual(reevaluateRules(rules, windows: windows), [.tile(id(1))])
    }

    func testFullscreenWindowsAreLeftAlone() {
        let rules = [WindowRule(app: "App", mode: .floating)]
        XCTAssertEqual(reevaluateRules(rules, windows: [window(1, mode: .fullscreen)]), [])
    }

    func testMinimizedWindowsAreReevaluatedToo() {
        let rules = [WindowRule(app: "App", mode: .floating)]
        XCTAssertEqual(reevaluateRules(rules, windows: [window(1, minimized: true)]), [.float(id(1))])
    }

    func testOtherAppsAreUnaffected() {
        let rules = [WindowRule(app: "Other", mode: .floating)]
        XCTAssertEqual(reevaluateRules(rules, windows: [window(1)]), [])
    }

    // MARK: Vanished purge

    func testWindowMissingFromScannedPidIsPurged() {
        let registered = [window(1), window(2)]
        let purge = vanishedWindowIDs(registered: registered, scannedPIDs: [10], present: [id(1)])
        XCTAssertEqual(purge, [id(2)])
    }

    func testUnscannedPidIsNeverPurged() {
        let registered = [window(1, pid: 11)]
        let purge = vanishedWindowIDs(registered: registered, scannedPIDs: [10], present: [])
        XCTAssertEqual(purge, [])
    }

    func testMinimizedWindowReturnedByScanSurvives() {
        let registered = [window(1, minimized: true)]
        let purge = vanishedWindowIDs(registered: registered, scannedPIDs: [10], present: [id(1)])
        XCTAssertEqual(purge, [])
    }

    func testVanishedMinimizedWindowIsPurged() {
        let registered = [window(1, minimized: true)]
        let purge = vanishedWindowIDs(registered: registered, scannedPIDs: [10], present: [])
        XCTAssertEqual(purge, [id(1)])
    }

    func testPurgeOrderIsDeterministic() {
        let registered = [window(3), window(1), window(2)]
        let purge = vanishedWindowIDs(registered: registered, scannedPIDs: [10], present: [])
        XCTAssertEqual(purge, [id(1), id(2), id(3)])
    }
}
