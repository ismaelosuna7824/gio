import Foundation

/// DA-06: whether Gio opens when the user logs in. macOS owns this state (a
/// login item the user can also change in System Settings > General > Login
/// Items), so it is read from the system, never stored in `config.toml`.
public enum LoginItemStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, waiting for the user's approval in System Settings.
    case requiresApproval
    /// Not running from an app bundle (for example `swift run`): this
    /// process cannot be a login item.
    case unavailable
}

/// The system's login item for Gio itself. Implemented by `SystemLoginItem`
/// (GioMacOS, `SMAppService.mainApp`).
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// A login launch starts quietly in the menu bar. Without Accessibility
/// nothing tiles, so the window still opens to say why.
public func opensMainWindowAtLaunch(launchedAtLogin: Bool, accessibilityGranted: Bool) -> Bool {
    !launchedAtLogin || !accessibilityGranted
}
