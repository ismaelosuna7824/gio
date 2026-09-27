import AppKit
import ApplicationServices
import CoreGraphics
import GioCore
import GioMac

@MainActor final class WorkspaceApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let bridge = AXWindowBridge()
    private let discovery = WindowDiscovery()
    private let names = WorkspacePreferences()
    private lazy var coordinator = WorkspaceCoordinator(bridge: bridge)
    private var displays: [DisplayID: CGRect] = [:]
    private var managed = Set<WindowID>()
    private var warning: String?
    private var displayChanged = false
    private var status: NSStatusItem!
    private var lastSwitchMilliseconds: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Gio"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        if let warning {
            let item = NSMenuItem(title: "Warning: \(warning)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let timing = NSMenuItem(title: lastSwitchMilliseconds.map { String(format: "Last switch: %.1f ms", $0) } ?? "Last switch: not measured", action: nil, keyEquivalent: "")
        timing.isEnabled = false
        menu.addItem(timing)
        let trusted = AXIsProcessTrusted()
        let permission = NSMenuItem(title: "Accessibility: \(trusted ? "Granted" : "Not granted")", action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        menu.addItem(NSMenuItem(title: "Request Accessibility Access…", action: #selector(requestAccess), keyEquivalent: ""))
        for id in displays.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            menu.addItem(.separator())
            let current = (try? coordinator.model.activeWorkspace(on: id))?.rawValue ?? "1"
            let heading = NSMenuItem(title: "Display \(id.rawValue) — \(names.name(for: Int(current) ?? 1))", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for number in 1...4 {
                let item = NSMenuItem(title: names.name(for: number), action: #selector(switchWorkspace(_:)), keyEquivalent: "")
                item.representedObject = (id.rawValue, number) as Any
                item.state = current == String(number) ? .on : .off
                item.isEnabled = trusted && !coordinator.recoveryRequired && !displayChanged
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Rename Workspace…", action: #selector(rename), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Windows", action: #selector(refreshAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Gio", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc private func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (String, Int) else { return }
        guard !displayChanged else { warn("Display configuration changed; quit to restore windows."); return }
        do {
            let start = ProcessInfo.processInfo.systemUptime
            try coordinator.switchTo(WorkspaceID(String(pair.1)), on: DisplayID(pair.0))
            lastSwitchMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            warning = nil
        }
        catch { warn("Switch failed: \(error)") }
    }

    @objc private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        alert.informativeText = "Choose a workspace number (1–4) and a name. Names apply to all displays."
        let number = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 240, height: 26))
        number.addItems(withTitles: (1...4).map(String.init))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Workspace name"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        view.addSubview(number)
        view.addSubview(field)
        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           !names.rename(number.indexOfSelectedItem + 1, to: field.stringValue) {
            warn("Name must contain 1–40 characters.")
        }
    }

    @objc private func refreshAction() { refresh() }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for id in discovery.forgetTerminatedProcess(app.processIdentifier) {
            if managed.contains(id) {
                do {
                    try coordinator.forgetClosedWindow(id)
                    managed.remove(id)
                } catch { warn("Could not forget terminated app window: \(error)"); continue }
            }
            bridge.forgetTerminatedWindow(id)
        }
    }

    private func reconcileClosedWindows() {
        guard AXIsProcessTrusted() else { return }
        let found = discovery.windows()
        for id in discovery.missingKnownIDs(from: found) where managed.contains(id) {
            do {
                if try bridge.isDefinitelyInvalid(id) {
                    try coordinator.forgetClosedWindow(id)
                    managed.remove(id)
                    discovery.forgetInvalidWindow(id)
                    bridge.forgetTerminatedWindow(id)
                } else {
                    warn("A managed window is missing from enumeration; ownership retained.")
                }
            } catch { warn("Window validity uncertain; ownership retained: \(error)") }
        }
    }

    private func refresh() {
        reconcileClosedWindows()
        guard !coordinator.recoveryRequired else { warn("Recovery needed; quit retries restoring windows."); return }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { warn("Cannot list displays."); return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { warn("Cannot list displays."); return }
        let current = Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map {
            (DisplayID(String($0)), CGDisplayBounds($0))
        })
        if !displays.isEmpty && current != displays {
            displayChanged = true
            warn("Display configuration changed. Quit to restore windows; reconnect support is deferred.")
            return
        }
        if displayChanged { return }
        if displays.isEmpty {
            do {
                for (id, rect) in current {
                    try coordinator.addDisplay(id, rect: rect, initialWorkspace: "1")
                    for number in 2...4 { try coordinator.addWorkspace(WorkspaceID(String(number)), on: id) }
                }
                displays = current
            } catch { warn("Display setup failed: \(error)"); return }
        }
        guard AXIsProcessTrusted() else { return }
        for (id, element, frame) in discovery.windows() where !managed.contains(id) {
            // A window spanning displays belongs to the display containing its center.
            guard let display = displays.first(where: { $0.value.contains(CGPoint(x: frame.midX, y: frame.midY)) })?.key else {
                warn("Some windows are outside connected displays and were not moved.")
                continue
            }
            do {
                try bridge.register(id, element: element)
                let active = try coordinator.model.activeWorkspace(on: display)
                try coordinator.assign(id, to: active, on: display)
                managed.insert(id)
            } catch { warn("Unsupported window was not managed: \(error)") }
        }
    }

    private func warn(_ message: String) { warning = message; status?.button?.title = "Gio ⚠" }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reconcileClosedWindows()
        do {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw WorkspaceCoordinatorError.recoveryRequired }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw WorkspaceCoordinatorError.recoveryRequired }
            let current = Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map {
                (DisplayID(String($0)), CGDisplayBounds($0))
            })
            try coordinator.shutdown(connectedDisplays: current)
            return .terminateNow
        }
        catch {
            warn("Restore failed; Gio remains running. Retry Quit. \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not restore windows"
            alert.informativeText = "Gio remains running. Retry Quit after checking Accessibility permission. \(error)"
            alert.runModal()
            return .terminateCancel
        }
    }
}
