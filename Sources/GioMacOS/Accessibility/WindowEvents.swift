import ApplicationServices
import AppKit
import Foundation

/// Event intake: per-app `AXObserver` subscriptions plus `NSWorkspace`
/// activation notes. Prints one line per event to stdout.
///
/// Covered notifications: window created, focused-window changed, moved,
/// resized, miniaturized, deminiaturized, title changed, element destroyed,
/// application activated. Registration is best-effort per app: an app that
/// refuses observation is reported once and skipped, never fatal.
///
/// The retained refcon labels intentionally live for the process lifetime.
public func listenForSystemWindowEvents() {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var observers: [AXObserver] = []
    observers.reserveCapacity(apps.count)
    var watched = 0
    for app in apps {
        let label = "app=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier)"
        guard observeApplication(pid: app.processIdentifier, label: label, keeping: &observers) else {
            print("[warn] observation refused: \(label)")
            continue
        }
        watched += 1
    }
    print("listening: watched=\(watched) apps=\(apps.count) (Ctrl-C to stop)")
    let center = NSWorkspace.shared.notificationCenter
    let token = center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: nil
    ) { note in
        let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .localizedName ?? "unknown"
        print("[event] app-activated app=\(name)")
    }
    _ = token
    RunLoop.main.run()
}

func observeApplication(
    pid: pid_t,
    label: String,
    keeping observers: inout [AXObserver]
) -> Bool {
    var observer: AXObserver?
    guard AXObserverCreate(
        pid,
        { _, _, notification, refcon in
            let context: String = {
                guard let refcon,
                      let label = Unmanaged<NSString>.fromOpaque(refcon).takeUnretainedValue()
                        as String?
                else {
                    return "app=<unknown>"
                }
                return label
            }()
            print("[event] \(context) notification=\(notification as String)")
        },
        &observer
    ) == .success,
        let observer
    else {
        return false
    }
    let appElement = AXUIElementCreateApplication(pid)
    for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] as [CFString] {
        addEventNotification(observer: observer, element: appElement, notification: notification, label: label)
    }
    var rawWindows: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        == .success,
        let elements = rawWindows as? [AXUIElement]
    {
        for element in elements where axIsStandardWindow(element) {
            for notification in [
                kAXWindowMovedNotification,
                kAXWindowResizedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
                kAXTitleChangedNotification,
                kAXUIElementDestroyedNotification,
            ] as [CFString] {
                addEventNotification(
                    observer: observer, element: element, notification: notification, label: label
                )
            }
        }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers.append(observer)
    return true
}

func addEventNotification(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    label: String
) {
    let refcon = Unmanaged.passRetained(label as NSString).toOpaque()
    let status = AXObserverAddNotification(observer, element, notification, refcon)
    if status != .success {
        Unmanaged<NSString>.fromOpaque(refcon).release()
    }
}
