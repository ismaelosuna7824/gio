import AppKit
import Darwin
import Foundation
import GioCore

/// WC-22: the names of every running process, so a window manager that runs
/// as a daemon (yabai) is found like one that is an app. One public
/// `sysctl(KERN_PROC_ALL)` read of every process's `p_comm` (the executable
/// name, 16 characters at most). Not `proc_name`: it answered ESRCH for other
/// processes (live 2026-11-04), so a running `yabai` went unseen.
public func runningProcessNames() -> Set<String> {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
        return []
    }
    // Room for processes started between the two calls.
    let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    size = capacity * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else {
        return []
    }
    var names = Set<String>()
    for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
        var command = processes[index].kp_proc.p_comm
        let name = withUnsafeBytes(of: &command) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if !name.isEmpty {
            names.insert(name)
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
