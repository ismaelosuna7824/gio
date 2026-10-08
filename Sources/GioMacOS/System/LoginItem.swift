import AppKit
import GioCore
import ServiceManagement

/// DA-06: Gio's own login item through `SMAppService.mainApp` (macOS 13).
/// It registers the bundle this process runs from, so a copy moved
/// elsewhere has to be turned on again from there.
public final class SystemLoginItem: LoginItemService {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public var status: LoginItemStatus {
        guard bundle.bundleURL.pathExtension == "app" else {
            return .unavailable
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Whether macOS launched this process as a login item. Only meaningful
/// inside `applicationDidFinishLaunching`, while the launch Apple event is
/// the current one.
public func launchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else {
        return false
    }
    return event.eventID == kAEOpenApplication
        && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
}
