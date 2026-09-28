import AppKit
import ApplicationServices
import CoreGraphics
import GioCore
import GioMac

@MainActor final class WorkspaceApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let bridge = AXWindowBridge()
    private let discovery = WindowDiscovery()
    private let preferences = WorkspacePreferences()
    private lazy var coordinator = NativeTilingCoordinator(bridge: bridge)
    private var displays: [LegacyDisplayID: CGRect] = [:]
    private var usable: [LegacyDisplayID: CGRect] = [:]
    private var skipped: [LegacyDisplayID: Int] = [:]
    private var pendingReflow = Set<LegacyDisplayID>()
    private var reflowScheduled = false
    private var applyingFrames = false
    private var managed = Set<LegacyWindowID>()
    private var spaceGeneration: UInt64 = 0
    private var warning: String?
    private var reflowFailures: [LegacyDisplayID: String] = [:]

    private var displayedWarning: String? {
        if gapDiverged { return divergenceWarning }
        if let warning, !coordinator.recoveryRequired { return warning }
        if !reflowFailures.isEmpty {
            return coordinator.recoveryRequired
                ? "Tiling failed; show error details. Recovery needed: retry Quit."
                : "Tiling failed; show error details. Retry tiling."
        }
        return warning
    }

    private func updateStatus() {
        status?.button?.title = displayedWarning == nil ? "Gio" : "Gio ⚠"
    }
    private var displayChanged = false
    private var gapDiverged = false
    private let divergenceWarning = "Gap rollback failed; saved gap may not match window geometry. Quit Gio to restore windows; retry Quit if restoration fails."
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Gio"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(self, selector: #selector(applicationChanged(_:)), name: event, object: nil)
        }
        center.addObserver(self, selector: #selector(applicationTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged(_:)),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        if let displayedWarning {
            let item = NSMenuItem(title: "Warning: \(displayedWarning)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !reflowFailures.isEmpty {
            menu.addItem(NSMenuItem(title: "Show Tiling Error Details…", action: #selector(showLastTilingError), keyEquivalent: ""))
        }
        let trusted = AXIsProcessTrusted()
        let permission = NSMenuItem(title: "Accessibility: \(trusted ? "Granted" : "Not granted")", action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        menu.addItem(NSMenuItem(title: "Request Accessibility Access…", action: #selector(requestAccess), keyEquivalent: ""))
        for id in displays.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Display \(id.rawValue) — current macOS Space", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let enabled = preferences.tilingEnabled(on: id.rawValue)
            let toggle = NSMenuItem(title: enabled ? "Disable Automatic Tiling" : "Enable Automatic Tiling",
                                    action: #selector(toggleTiling(_:)), keyEquivalent: "")
            toggle.representedObject = id.rawValue
            toggle.isEnabled = trusted && !gapDiverged && !coordinator.recoveryRequired && !displayChanged && (enabled || usable[id] != nil)
            menu.addItem(toggle)
            if enabled {
                let count = skipped[id].map(String.init) ?? "unknown (retry Refresh Windows)"
                let item = NSMenuItem(title: "Candidates not tiled: \(count)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let gapMenu = NSMenu()
        for value in [0, 8, 16] {
            let item = NSMenuItem(title: "\(value) pt", action: #selector(changeGap(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = preferences.gap == value ? .on : .off
            item.isEnabled = trusted && !gapDiverged && !displayChanged && !coordinator.recoveryRequired
            gapMenu.addItem(item)
        }
        let gapItem = NSMenuItem(title: "Tiling gaps (outer / inner)", action: nil, keyEquivalent: "")
        menu.setSubmenu(gapMenu, for: gapItem)
        menu.addItem(gapItem)
        menu.addItem(NSMenuItem(title: "Refresh Windows", action: #selector(refreshAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Gio", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc private func showLastTilingError() {
        guard !reflowFailures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Tiling error details"
        alert.informativeText = reflowFailures.keys.sorted { $0.rawValue < $1.rawValue }
            .compactMap { reflowFailures[$0] }.joined(separator: "\n\n")
        alert.runModal()
    }

    @objc private func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func refreshAction() { refresh() }

    @objc private func toggleTiling(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let id = LegacyDisplayID(raw)
        guard !gapDiverged else { warn(divergenceWarning); return }
        guard AXIsProcessTrusted(), !displayChanged, !coordinator.recoveryRequired else {
            warn("Grant Accessibility access and resolve recovery before changing tiling."); return
        }
        if preferences.tilingEnabled(on: raw) {
            do {
                try coordinator.restoreTiledFrames(on: id)
                preferences.setTilingEnabled(false, on: raw)
                skipped.removeValue(forKey: id)
                reflowFailures.removeValue(forKey: id)
                updateStatus()
            } catch { warn("Could not disable tiling; retry or Quit to restore: \(error)") }
        } else {
            guard usable[id] != nil else { warn("No safe visible work area for this display; check display settings."); return }
            if reflow(id) { preferences.setTilingEnabled(true, on: raw) }
        }
    }

    @objc private func changeGap(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int, [0, 8, 16].contains(value),
              AXIsProcessTrusted(), !gapDiverged, !coordinator.recoveryRequired, !displayChanged else { return }
        let old = preferences.gap
        guard value != old else { return }
        let enabled = displays.keys.sorted { $0.rawValue < $1.rawValue }
            .filter { preferences.tilingEnabled(on: $0.rawValue) }
        let outcome = GapChangeTransaction.run(displays: enabled, newGap: value, oldGap: old) { id, gap in
            reflow(id, gap: gap)
        }
        switch outcome {
        case .applied: _ = preferences.setGap(value)
        case .reverted: warn("Gap change failed; previous layout and setting retained. Retry or Quit to restore windows.")
        case .divergent:
            gapDiverged = true
            pendingReflow.removeAll()
            warn(divergenceWarning)
        }
    }

    @discardableResult private func reflow(_ id: LegacyDisplayID, gap: Int? = nil) -> Bool {
        guard !gapDiverged, !applyingFrames, !displayChanged, let bounds = usable[id], AXIsProcessTrusted(),
              !coordinator.recoveryRequired else { return false }
        applyingFrames = true
        defer { applyingFrames = false }
        do {
            // Every display gets a fresh complete snapshot; A's writes cannot validate B.
            let generation = spaceGeneration
            let snapshot = try SpaceWindowSnapshot.capture(generation: generation,
                currentGeneration: { self.spaceGeneration }, discovery: discovery)
            let result = SpaceWindowEligibility.evaluate(ax: snapshot.windows.map(\.candidate),
                axGeneration: snapshot.generation, onScreen: snapshot.onScreen,
                cgGeneration: snapshot.generation, currentGeneration: spaceGeneration)
            guard generation == spaceGeneration else { throw SpaceWindowSnapshotError.staleSnapshot }
            let selected = Set(result.eligibleWindowIDs)
            let candidates = SpaceWindowEligibility.onScreenCandidates(
                ax: snapshot.windows.map(\.candidate), onScreen: snapshot.onScreen,
                display: displays[id] ?? .null)
            let windows = snapshot.windows.filter { candidates.contains($0.id) && selected.contains($0.id) }
            for window in windows {
                try bridge.register(window.id, element: window.element)
                try coordinator.adopt(window.id, on: id)
                managed.insert(window.id)
            }
            guard generation == spaceGeneration else { throw SpaceWindowSnapshotError.staleSnapshot }
            let unsupported = try coordinator.reflow(on: id, selected: Set(windows.map(\.id)),
                usableBounds: bounds, outerGap: CGFloat(gap ?? preferences.gap),
                innerGap: CGFloat(gap ?? preferences.gap))
            skipped[id] = candidates.count - windows.count + unsupported.count
            reflowFailures.removeValue(forKey: id)
            updateStatus()
            return true
        } catch {
            skipped.removeValue(forKey: id)
            let retry = preferences.tilingEnabled(on: id.rawValue) ? "Refresh Windows" : "Enable Automatic Tiling"
            let nextStep = coordinator.recoveryRequired
                ? "Recovery needed; Quit retries restoring windows."
                : "Retry \(retry)."
            // Diagnostics only: fresh NSScreen read at failure time, never the cache.
            // No behavior change — fail-closed handling below stays exactly as is.
            let diagnostics = failureDiagnostics(for: id, error: error)
            reflowFailures[id] = "Tiling failed on display \(id.rawValue). \(nextStep) Error: \(error)\(diagnostics.isEmpty ? "" : " \(diagnostics)")"
            if !gapDiverged && warning != nil && !coordinator.recoveryRequired { warning = nil }
            updateStatus()
            return false
        }
    }

    /// Builds the log-only diagnostics appended to a tiling-failure message.
    /// Reads live display state; never refreshes or mutates the `usable` cache.
    private func failureDiagnostics(for id: LegacyDisplayID, error: Error) -> String {
        var parts: [String] = []
        if Self.isShrinkMismatch(error) {
            parts.append("shrink=true (AX applied a smaller frame than requested; cached usable bounds may be stale)")
        }
        if let line = freshVisibleAreaLine(for: id) { parts.append(line) }
        return parts.joined(separator: " ")
    }

    /// True when the failure carries a frame mismatch where AX applied a
    /// smaller frame than requested — the stale-usable-bounds signature.
    private static func isShrinkMismatch(_ error: Error) -> Bool {
        let candidates: [Error]
        if case NativeTilingError.operationFailed(let underlying, _) = error {
            candidates = [underlying, error]
        } else {
            candidates = [error]
        }
        for candidate in candidates {
            if let frames = (candidate as? WindowFrameMismatch)?.mismatchedFrames,
               frames.actual.width < frames.requested.width
                || frames.actual.height < frames.requested.height {
                return true
            }
        }
        return false
    }

    /// Fresh visible-area snapshot for one display: live CG bounds plus a live
    /// NSScreen read. Returns nil when the display has no matching live screen.
    private func freshVisibleAreaLine(for id: LegacyDisplayID) -> String? {
        guard let number = UInt32(id.rawValue) else { return nil }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number))
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  String(screenNumber.uint32Value) == id.rawValue else { continue }
            return VisibleAreaDiagnostic(displayID: id.rawValue, displayBounds: bounds,
                                         screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                         cachedUsable: usable[id]).summary()
        }
        return nil
    }

    private func scheduleReflow(_ ids: Set<LegacyDisplayID>) {
        guard !gapDiverged else { return }
        pendingReflow.formUnion(ids.filter { preferences.tilingEnabled(on: $0.rawValue) })
        guard !pendingReflow.isEmpty, !reflowScheduled else { return }
        reflowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.reflowScheduled = false
            let pending = self.pendingReflow
            self.pendingReflow.removeAll()
            self.refresh(reflowDiscovered: false)
            for id in pending where self.preferences.tilingEnabled(on: id.rawValue) { _ = self.reflow(id) }
        }
    }

    @objc private func spaceChanged(_ notification: Notification) {
        spaceGeneration &+= 1
        scheduleReflow(Set(displays.keys))
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
            coordinator.forgetClosedWindow(id)
            managed.remove(id)
            bridge.forgetTerminatedWindow(id)
        }
        scheduleReflow(Set(displays.keys))
    }

    private func refresh(reflowDiscovered: Bool = true) {
        guard !gapDiverged else { return }
        guard !coordinator.recoveryRequired else {
            if reflowFailures.isEmpty { warn("Recovery needed; quit retries restoring windows.") }
            return
        }
        do {
            let current = try connectedDisplays()
            if !displays.isEmpty && current != displays {
                displayChanged = true
                warn("Display configuration changed. Quit to restore windows; reconnect support is deferred.")
                return
            }
            if displayChanged { return }
            var visible: [LegacyDisplayID: CGRect] = [:]
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let id = LegacyDisplayID(String(number.uint32Value))
                guard let full = current[id], let area = DisplayUsableBounds.convert(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame, displayBounds: full) else { continue }
                guard visible[id] == nil else { throw NativeTilingError.recoveryRequired }
                visible[id] = area
            }
            usable = visible
            if displays.isEmpty {
                for (id, rect) in current { try coordinator.registerDisplay(id, bounds: rect) }
                displays = current
            }
            if reflowDiscovered {
                for id in displays.keys where preferences.tilingEnabled(on: id.rawValue) { _ = reflow(id) }
            }
        } catch { warn("Cannot refresh displays; retry Refresh Windows or Quit: \(error)") }
    }

    private func connectedDisplays() throws -> [LegacyDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw NativeTilingError.recoveryRequired }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw NativeTilingError.recoveryRequired }
        var current: [LegacyDisplayID: CGRect] = [:]
        for cgID in ids.prefix(Int(count)) {
            let id = LegacyDisplayID(String(cgID))
            guard current[id] == nil else { throw NativeTilingError.recoveryRequired }
            current[id] = CGDisplayBounds(cgID)
        }
        return current
    }

    private func warn(_ message: String) {
        warning = gapDiverged ? divergenceWarning : message
        updateStatus()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try coordinator.shutdown(connectedDisplays: connectedDisplays())
            return .terminateNow
        } catch {
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
