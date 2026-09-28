import ApplicationServices
import AppKit
import Foundation

/// Event intake: per-app `AXObserver` subscriptions plus `NSWorkspace`
/// activation notes.
///
/// Covered notifications: window created, focused-window changed, moved,
/// resized, miniaturized, deminiaturized, title changed, element destroyed,
/// application activated. Registration is best-effort per app: an app that
/// refuses observation is reported once and skipped, never fatal.
///
/// Two flavors: `listenForSystemWindowEvents()` prints and runs forever
/// (the `gio-poc events` verb); `SystemWindowObserver` keeps subscriptions
/// alive for hosts and forwards lines to a callback. Create the observer on
/// the thread whose run loop drives delivery (main, for app hosts).
///
/// Retained refcons intentionally live for the process lifetime.
public func listenForSystemWindowEvents() {
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
    let observer = SystemWindowObserver { print($0) }
    print("listening: watched=\(observer.watchedCount) (Ctrl-C to stop)")
    RunLoop.main.run()
}

/// Retainable AX subscription set. Releasing drops the observers; call
/// `stop()` first to detach run-loop sources explicitly.
public final class SystemWindowObserver {
    private var observers: [AXObserver] = []
    private var activationToken: NSObjectProtocol?
    public private(set) var watchedCount = 0
    public private(set) var refused: [String] = []

    public init(onEvent: @escaping @Sendable (String) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            let label = "app=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier)"
            if observeApplication(
                pid: app.processIdentifier, label: label,
                keeping: &observers, emit: onEvent
            ) {
                watchedCount += 1
            } else {
                refused.append(label)
            }
        }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { note in
            let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .localizedName ?? "unknown"
            onEvent("[event] app-activated app=\(name)")
        }
    }

    public func stop() {
        if let token = activationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activationToken = nil
        }
        for observer in observers {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode
            )
        }
        observers = []
    }
}

/// Refcon box: the AX callback cannot capture, so everything it needs
/// travels here. Nil `emit` prints (the CLI path).
final class EventRefcon: @unchecked Sendable {
    let label: String
    let emit: (@Sendable (String) -> Void)?

    init(label: String, emit: (@Sendable (String) -> Void)?) {
        self.label = label
        self.emit = emit
    }
}

func observeApplication(
    pid: pid_t,
    label: String,
    keeping observers: inout [AXObserver],
    emit: (@Sendable (String) -> Void)? = nil
) -> Bool {
    var observer: AXObserver?
    guard AXObserverCreate(
        pid,
        { _, _, notification, refcon in
            guard let refcon else {
                print("[event] app=<unknown> notification=\(notification as String)")
                return
            }
            let box: EventRefcon = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
            let line = "[event] \(box.label) notification=\(notification as String)"
            if let emit = box.emit {
                emit(line)
            } else {
                print(line)
            }
        },
        &observer
    ) == .success,
        let observer
    else {
        return false
    }
    let appElement = AXUIElementCreateApplication(pid)
    for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] as [CFString] {
        addEventNotification(
            observer: observer, element: appElement, notification: notification,
            label: label, emit: emit
        )
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
                    observer: observer, element: element, notification: notification,
                    label: label, emit: emit
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
    label: String,
    emit: (@Sendable (String) -> Void)? = nil
) {
    let refcon = Unmanaged.passRetained(EventRefcon(label: label, emit: emit)).toOpaque()
    let status = AXObserverAddNotification(observer, element, notification, refcon)
    if status != .success {
        Unmanaged<EventRefcon>.fromOpaque(refcon).release()
    }
}
