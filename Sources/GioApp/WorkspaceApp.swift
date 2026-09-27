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
    private var usable: [DisplayID: CGRect] = [:]
    private var skipped: [DisplayID: Int] = [:]
    private var pendingReflow = Set<DisplayID>()
    private var reflowScheduled = false
    private var applyingFrames = false
    private var managed = Set<WindowID>()
    private var warning: String?
    private var displayChanged = false
    private var gapDiverged = false
    private let divergenceWarning = "Gap rollback failed; saved gap may not match window geometry. Quit Gio to restore windows; retry Quit if restoration fails."
    private var status: NSStatusItem!
    private var lastSwitchMilliseconds: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Gio"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationChanged(_:)),
                name: event, object: nil)
        }
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
            let enabled = names.tilingEnabled(on: id.rawValue)
            let toggle = NSMenuItem(title: enabled ? "Disable Automatic Tiling" : "Enable Automatic Tiling",
                                    action: #selector(toggleTiling(_:)), keyEquivalent: "")
            toggle.representedObject = id.rawValue
            toggle.isEnabled = trusted && !gapDiverged && !coordinator.recoveryRequired && !displayChanged && (enabled || usable[id] != nil)
            menu.addItem(toggle)
            if enabled {
                let count = skipped[id] ?? 0
                let item = NSMenuItem(title: "Unsupported windows skipped: \(count)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for number in 1...4 {
                let item = NSMenuItem(title: names.name(for: number), action: #selector(switchWorkspace(_:)), keyEquivalent: "")
                item.representedObject = (id.rawValue, number) as Any
                item.state = current == String(number) ? .on : .off
                item.isEnabled = trusted && !gapDiverged && !coordinator.recoveryRequired && !displayChanged
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let gapMenu = NSMenu()
        for value in [0, 8, 16] {
            let item = NSMenuItem(title: "\(value) pt", action: #selector(changeGap(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = names.gap == value ? .on : .off
            item.isEnabled = trusted && !gapDiverged && !displayChanged && !coordinator.recoveryRequired
            gapMenu.addItem(item)
        }
        let gapItem = NSMenuItem(title: "Tiling gaps (outer / inner)", action: nil, keyEquivalent: "")
        menu.setSubmenu(gapMenu, for: gapItem)
        menu.addItem(gapItem)
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
        guard !gapDiverged else { warn(divergenceWarning); return }
        guard !displayChanged else { warn("Display configuration changed; quit to restore windows."); return }
        do {
            let start = ProcessInfo.processInfo.systemUptime
            try coordinator.switchTo(WorkspaceID(String(pair.1)), on: DisplayID(pair.0))
            lastSwitchMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            if names.tilingEnabled(on: pair.0) { reflow(DisplayID(pair.0)) }
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

    @objc private func toggleTiling(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let id = DisplayID(raw)
        guard !gapDiverged else { warn(divergenceWarning); return }
        guard AXIsProcessTrusted(), !displayChanged, !coordinator.recoveryRequired else {
            warn("Grant Accessibility access and resolve recovery before changing tiling."); return
        }
        if names.tilingEnabled(on: raw) {
            do {
                try coordinator.restoreTiledFrames(on: id)
                names.setTilingEnabled(false, on: raw)
                skipped.removeValue(forKey: id)
                warning = nil
            } catch { warn("Could not disable tiling; retry or Quit to restore: \(error)") }
        } else {
            guard usable[id] != nil else { warn("No safe visible work area for this display; check display settings."); return }
            if reflow(id) { names.setTilingEnabled(true, on: raw) }
        }
    }

    @objc private func changeGap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int, [0, 8, 16].contains(value),
              AXIsProcessTrusted(), !gapDiverged, !coordinator.recoveryRequired, !displayChanged else { return }
        let old = names.gap
        guard value != old else { return }
        let enabled = displays.keys.sorted { $0.rawValue < $1.rawValue }
            .filter { names.tilingEnabled(on: $0.rawValue) }
        let outcome = GapChangeTransaction.run(displays: enabled, newGap: value, oldGap: old) { id, gap in
            reflow(id, gap: gap)
        }
        switch outcome {
        case .applied: _ = names.setGap(value)
        case .reverted: warn("Gap change failed; previous layout and setting retained. Retry or Quit to restore windows.")
        case .divergent:
            gapDiverged = true
            pendingReflow.removeAll()
            warn(divergenceWarning)
        }
    }

    @discardableResult private func reflow(_ id: DisplayID, gap: Int? = nil) -> Bool {
        guard !gapDiverged, !applyingFrames, !displayChanged, let bounds = usable[id], AXIsProcessTrusted(),
              !coordinator.recoveryRequired else { return false }
        applyingFrames = true
        defer { applyingFrames = false }
        do {
            let value = CGFloat(gap ?? names.gap)
            skipped[id] = try coordinator.reflow(on: id, usableBounds: bounds,
                                                  outerGap: value, innerGap: value).count
            warning = nil
            return true
        } catch {
            warn("Tiling failed on display \(id.rawValue); some windows may remain unchanged. Retry Refresh Windows or Quit: \(error)")
            return false
        }
    }

    private func scheduleReflow(_ ids: Set<DisplayID>) {
        guard !gapDiverged else { return }
        pendingReflow.formUnion(ids.filter { names.tilingEnabled(on: $0.rawValue) })
        guard !pendingReflow.isEmpty, !reflowScheduled else { return }
        reflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.reflowScheduled = false
            let pending = self.pendingReflow
            self.pendingReflow.removeAll()
            self.refresh(reflowDiscovered: false)
            for id in pending where self.names.tilingEnabled(on: id.rawValue) { _ = self.reflow(id) }
        }
    }

    @objc private func applicationChanged(_ notification: Notification) {
        guard !applyingFrames,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        scheduleReflow(Set(displays.keys))
    }

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
        scheduleReflow(Set(displays.keys))
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

    private func refresh(reflowDiscovered: Bool = true) {
        guard !gapDiverged else { return }
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
        let visible = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (DisplayID, CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let cgID = CGDirectDisplayID(number.uint32Value)
            let id = DisplayID(String(cgID))
            guard let full = current[id],
                  let area = DisplayUsableBounds.convert(screenFrame: screen.frame,
                                                         visibleFrame: screen.visibleFrame,
                                                         displayBounds: full) else { return nil }
            return (id, area)
        })
        usable = visible
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
        var discovered = Set<DisplayID>()
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
                discovered.insert(display)
            } catch { warn("Unsupported window was not managed: \(error)") }
        }
        if reflowDiscovered {
            for id in discovered where names.tilingEnabled(on: id.rawValue) { _ = reflow(id) }
        }
    }

    private func warn(_ message: String) {
        warning = gapDiverged ? divergenceWarning : message
        status?.button?.title = "Gio ⚠"
    }

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
