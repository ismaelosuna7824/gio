import ApplicationServices
import Foundation
import GioCore

/// PF-K: `AXEnhancedUserInterface` on the app element, over public
/// Accessibility calls (the attribute itself is undocumented; assistive apps
/// such as VoiceOver set it). The decisions (when, which apps, restore and
/// retry) live in `EnhancedUIGuard`; this only reads and writes it, with the
/// actuator's short messaging timeout, and refuses Gio's own pid (AX calls on
/// in-process elements run AppKit on the calling lane thread).
public final class AXEnhancedUserInterfaceSwitch: EnhancedUserInterfaceSwitch, @unchecked Sendable {
    private let attribute = "AXEnhancedUserInterface" as CFString
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    public func enhancedUserInterface(pid: pid_t) -> Bool? {
        guard let app = application(pid) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    public func setEnhancedUserInterface(_ on: Bool, pid: pid_t) -> Bool {
        guard let app = application(pid) else {
            return false
        }
        let value: CFBoolean = on ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(app, attribute, value) == .success
    }

    private func application(_ pid: pid_t) -> AXUIElement? {
        guard pid > 0, pid != ownPID, (try? actuatorPermission()) != nil else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, AXWindowActuator.messagingTimeoutSeconds)
        return app
    }
}
