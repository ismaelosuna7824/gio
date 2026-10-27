import Combine
import GioCore
@testable import GioUI
import XCTest

/// DA-06: the Open at Login switch reflects the system's login item state,
/// which the user can also change in System Settings.
@MainActor
final class LoginItemTests: XCTestCase {
    private final class FakeLoginItem: LoginItemService {
        var status: LoginItemStatus
        var statusAfterChange: LoginItemStatus?
        var failure: Error?
        var openedSettings = 0

        init(_ status: LoginItemStatus) {
            self.status = status
        }

        func setEnabled(_ enabled: Bool) throws {
            if let failure {
                throw failure
            }
            status = statusAfterChange ?? (enabled ? .enabled : .disabled)
        }

        func openSystemSettings() {
            openedSettings += 1
        }
    }

    private var logs: [(LogLevel, String)] = []

    private func model(_ service: FakeLoginItem) -> LoginItemModel {
        LoginItemModel(service: service, log: { [weak self] in self?.logs.append(($0, $1)) })
    }

    func testEachStatusShowsTheSwitchTheUserExpects() {
        let enabled = loginItemPresentation(status: .enabled, error: nil)
        XCTAssertTrue(enabled.isOn)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(enabled.showsApprove)

        let disabled = loginItemPresentation(status: .disabled, error: nil)
        XCTAssertFalse(disabled.isOn)
        XCTAssertTrue(disabled.isEnabled)

        // Registered but not approved yet: on, with the way to approve it.
        let pending = loginItemPresentation(status: .requiresApproval, error: nil)
        XCTAssertTrue(pending.isOn)
        XCTAssertTrue(pending.showsApprove)
        XCTAssertTrue(pending.caption.contains("Login Items"))

        // Not an app bundle (swift run): the switch cannot work.
        let unavailable = loginItemPresentation(status: .unavailable, error: nil)
        XCTAssertFalse(unavailable.isOn)
        XCTAssertFalse(unavailable.isEnabled)
    }

    func testTurningItOnFollowsWhatTheSystemReports() {
        let service = FakeLoginItem(.disabled)
        service.statusAfterChange = .requiresApproval
        let model = model(service)

        model.set(true)

        XCTAssertEqual(model.status, .requiresApproval)
        XCTAssertNil(model.error)
        XCTAssertEqual(logs.map(\.1), ["login item set enabled=true status=requiresApproval"])
    }

    func testAFailedChangeKeepsTheRealStateAndSaysWhy() {
        let service = FakeLoginItem(.disabled)
        service.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Operation not permitted",
        ])
        let model = model(service)

        model.set(true)

        XCTAssertEqual(model.status, .disabled)
        XCTAssertEqual(model.error, "Operation not permitted")
        XCTAssertFalse(model.presentation.isOn)
        XCTAssertTrue(model.presentation.caption.contains("Operation not permitted"))
        XCTAssertEqual(logs.map(\.0), [.warn])
        XCTAssertEqual(logs.map(\.1), ["login item set failed enabled=true code=1"])
    }

    func testRefreshPicksUpAChangeMadeInSystemSettingsAndClearsAnOldError() {
        let service = FakeLoginItem(.disabled)
        service.failure = NSError(domain: "x", code: 2)
        let model = model(service)
        model.set(true)
        XCTAssertNotNil(model.error)

        service.status = .enabled
        model.refresh()

        XCTAssertEqual(model.status, .enabled)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.presentation.isOn)
    }

    /// PA-12: polling an unchanged login item publishes nothing.
    func testRefreshWithAnUnchangedStatusPublishesNothing() {
        let model = model(FakeLoginItem(.enabled))
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        model.refresh()
        model.refresh()

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.status, .enabled)
    }
}
