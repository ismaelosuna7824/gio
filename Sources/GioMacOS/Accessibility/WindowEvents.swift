import ApplicationServices
import AppKit
import Foundation

/// One observed event, tagged with the process it came from.
public struct SystemWindowEvent: Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case appLaunched
        case appTerminated
        case appActivated
        /// An `AXObserver` notification (window created, moved, ...).
        case accessibility
    }

    public let kind: Kind
    public let pid: pid_t
    public let label: String
    public let notification: String?

    public init(kind: Kind, pid: pid_t, label: String, notification: String? = nil) {
        self.kind = kind
        self.pid = pid
        self.label = label
        self.notification = notification
    }

    public var description: String {
        switch kind {
        case .appLaunched: return "[event] app-launched \(label)"
        case .appTerminated: return "[event] app-terminated \(label)"
        case .appActivated: return "[event] app-activated \(label)"
        case .accessibility: return "[event] \(label) notification=\(notification ?? "?")"
        }
    }
}

/// Event intake: per-app `AXObserver` subscriptions plus `NSWorkspace`
/// launch / terminate / activation notes.
///
/// Covered notifications: window created, focused-window changed, moved,
/// resized, miniaturized, deminiaturized, title changed, element destroyed,
/// application activated, launched and terminated.
///
/// Observers are per pid: `attach(pid:)` / `detach(pid:)` add and drop one
/// app without touching the others. Attaching is best-effort and returns
/// false when the app refuses (Accessibility not ready yet); the caller owns
/// the retry policy. Run-loop sources always go on the MAIN run loop so
/// attach/detach may be called from any thread; events are delivered on the
/// main thread.
///
/// Two flavors: `listenForSystemWindowEvents()` prints and runs forever
/// (the `gio-poc events` verb); hosts keep a `SystemWindowObserver` alive
/// and forward events to a callback.
public func listenForSystemWindowEvents() {
    let observer = SystemWindowObserver { print($0) }
    let refused = observer.attachAllRunningApps()
    print("listening: watched=\(observer.watchedCount) refused=\(refused.count) (Ctrl-C to stop)")
    RunLoop.main.run()
}

public final class SystemWindowObserver: @unchecked Sendable {
    /// The AX observer plus the refcon box it points at. Dropping the record
    /// releases both together, so no callback can outlive its context.
    private struct Record {
        let observer: AXObserver
        let context: EventRefcon
    }

    private let lock = NSLock()
    private var records: [pid_t: Record] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let onEvent: @Sendable (SystemWindowEvent) -> Void

    public init(onEvent: @escaping @Sendable (SystemWindowEvent) -> Void) {
        self.onEvent = onEvent
        let center = NSWorkspace.shared.notificationCenter
        func app(_ note: Notification) -> NSRunningApplication? {
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { note in
            guard let app = app(note) else { return }
            onEvent(SystemWindowEvent(
                kind: .appActivated, pid: app.processIdentifier, label: Self.label(for: app)
            ))
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { note in
            guard let app = app(note), app.activationPolicy == .regular else { return }
            onEvent(SystemWindowEvent(
                kind: .appLaunched, pid: app.processIdentifier, label: Self.label(for: app)
            ))
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { note in
            guard let app = app(note) else { return }
            onEvent(SystemWindowEvent(
                kind: .appTerminated, pid: app.processIdentifier, label: Self.label(for: app)
            ))
        })
    }

    public var watchedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    public var attachedPIDs: Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return Set(records.keys)
    }

    /// Attach to every running regular app. Returns the labels that refused.
    @discardableResult
    public func attachAllRunningApps() -> [String] {
        var refused: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if !attach(pid: app.processIdentifier) {
                refused.append(Self.label(for: app))
            }
        }
        return refused
    }

    /// Subscribe to one app. True when it is observed afterwards (including
    /// "already was"); false when the app refused, so the caller can retry.
    @discardableResult
    public func attach(pid: pid_t) -> Bool {
        lock.lock()
        let already = records[pid] != nil
        lock.unlock()
        if already {
            return true
        }
        let label = NSRunningApplication(processIdentifier: pid).map(Self.label(for:))
            ?? "pid=\(pid)"
        let context = EventRefcon(pid: pid, label: label, emit: onEvent)
        guard let observer = makeObserver(pid: pid, context: context) else {
            return false
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        lock.lock()
        records[pid] = Record(observer: observer, context: context)
        lock.unlock()
        return true
    }

    /// Drop one app's observer; the other apps are untouched.
    public func detach(pid: pid_t) {
        lock.lock()
        let record = records.removeValue(forKey: pid)
        lock.unlock()
        if let record {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(record.observer), .defaultMode
            )
        }
    }

    /// Detach everything and stop workspace notifications.
    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens = []
        for pid in attachedPIDs {
            detach(pid: pid)
        }
    }

    static func label(for app: NSRunningApplication) -> String {
        "app=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier)"
    }

    private func makeObserver(pid: pid_t, context: EventRefcon) -> AXObserver? {
        var created: AXObserver?
        guard AXObserverCreate(
            pid,
            { _, _, notification, refcon in
                guard let refcon else {
                    return
                }
                let box: EventRefcon = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
                box.emit(SystemWindowEvent(
                    kind: .accessibility, pid: box.pid, label: box.label,
                    notification: notification as String
                ))
            },
            &created
        ) == .success,
            let observer = created
        else {
            return nil
        }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        // The app-level window-created subscription is what covers windows
        // opened later; if it fails the app is not ready and the attach
        // counts as refused so the caller retries.
        let created1 = AXObserverAddNotification(
            observer, appElement, kAXWindowCreatedNotification as CFString, refcon
        )
        guard created1 == .success || created1 == .notificationAlreadyRegistered else {
            return nil
        }
        _ = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon
        )
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
                    _ = AXObserverAddNotification(observer, element, notification, refcon)
                }
            }
        }
        return observer
    }
}

/// Refcon box: the AX callback cannot capture, so everything it needs
/// travels here. Owned by the observer's `Record`.
final class EventRefcon: @unchecked Sendable {
    let pid: pid_t
    let label: String
    let emit: @Sendable (SystemWindowEvent) -> Void

    init(pid: pid_t, label: String, emit: @escaping @Sendable (SystemWindowEvent) -> Void) {
        self.pid = pid
        self.label = label
        self.emit = emit
    }
}
