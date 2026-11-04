import AppKit
import Darwin
import Foundation
import GioCore

/// WC-22: the names of every running process (public libproc), so a window
/// manager that runs as a daemon (yabai) is found like one that is an app.
public func runningProcessNames() -> Set<String> {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    guard capacity > 64 else {
        return []
    }
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var names = Set<String>()
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            names.insert(String(cString: buffer))
        }
    }
    return names
}

/// WC-22: watches for another window manager. It checks at start, whenever
/// an app launches or quits, and every `interval` (a daemon such as yabai
/// starts without an app launch); `onChange` runs on the main thread only
/// when the answer changes. The decision is `conflictingWindowManagers` in
/// GioCore.
public final class WindowManagerMonitor: @unchecked Sendable {
    public static let interval: TimeInterval = 15

    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "gio.window-manager-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    /// Read and written on `queue` only.
    private var last: [String] = []

    public init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    /// Main thread, once.
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.check() }
            })
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    private func check() {
        let names = conflictingWindowManagers(runningProcessNames: runningProcessNames())
        guard names != last else {
            return
        }
        last = names
        DispatchQueue.main.async { [onChange] in
            onChange(names)
        }
    }
}
