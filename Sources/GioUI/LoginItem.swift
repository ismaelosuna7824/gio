import Foundation
import GioCore

/// DA-06: what the Open at Login row shows for a login item state.
public struct LoginItemPresentation: Equatable, Sendable {
    public var isOn: Bool
    /// False when this process cannot be a login item at all.
    public var isEnabled: Bool
    public var caption: String
    /// Registered but not approved: offer System Settings > Login Items.
    public var showsApprove: Bool
}

public func loginItemPresentation(status: LoginItemStatus, error: String?) -> LoginItemPresentation {
    var presentation: LoginItemPresentation
    switch status {
    case .enabled:
        presentation = LoginItemPresentation(
            isOn: true, isEnabled: true, caption: "Gio starts in the menu bar when you log in.", showsApprove: false
        )
    case .disabled:
        presentation = LoginItemPresentation(
            isOn: false, isEnabled: true, caption: "Start Gio in the menu bar when you log in.", showsApprove: false
        )
    case .requiresApproval:
        presentation = LoginItemPresentation(
            isOn: true, isEnabled: true,
            caption: "Allow Gio in System Settings > General > Login Items to finish.", showsApprove: true
        )
    case .unavailable:
        presentation = LoginItemPresentation(
            isOn: false, isEnabled: false, caption: "Only the Gio app can open at login.", showsApprove: false
        )
    }
    if let error {
        presentation.caption = "Could not change it: \(error)"
    }
    return presentation
}

/// The Open at Login switch. Every change re-reads the system state, which
/// is the only truth (the user can flip it in System Settings too).
@MainActor
public final class LoginItemModel: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var error: String?
    private let service: LoginItemService
    private let log: (LogLevel, String) -> Void

    public init(
        service: LoginItemService,
        log: @escaping (LogLevel, String) -> Void = { level, message in GioLog.record(level, message) }
    ) {
        self.service = service
        self.log = log
        status = service.status
    }

    public var presentation: LoginItemPresentation {
        loginItemPresentation(status: status, error: error)
    }

    public func refresh() {
        let current = service.status
        if current != status {
            error = nil
        }
        status = current
    }

    public func set(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            error = nil
            status = service.status
            log(.info, "login item set enabled=\(enabled) status=\(status.rawValue)")
        } catch {
            self.error = error.localizedDescription
            status = service.status
            log(.warn, "login item set failed enabled=\(enabled) code=\((error as NSError).code)")
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }
}
