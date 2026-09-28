import AppKit
import Foundation
import GioMacOS
import GioUI
import SwiftUI

@MainActor
func activateGio() {
    if #available(macOS 14.0, *) {
        NSApplication.shared.activate()
    } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The unified Gio app: menu bar, launcher window and debug console over
/// one session host (config, lock, IPC server, registry, workspaces,
/// displays, actuator, event intake, hotkey tap). One process, accessory
/// policy (no Dock icon). The `gio` CLI talks to it over IPC; the signed
/// .app bundle is 1.0 packaging work.
@MainActor
final class GioDesktopDelegate: NSObject, NSApplicationDelegate {
    private let host = SessionHost()
    private var bar: MenuBarController?
    private var launcherWindow: NSWindow?
    private var labWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = host.start() {
            print("[gio] cannot start: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        let bar = MenuBarController()
        bar.onOpenLauncher = { [weak self] in self?.showLauncher() }
        bar.onOpenDebug = { [weak self] in self?.toggleLab() }
        bar.start()
        self.bar = bar
        host.onSummonLauncher = { [weak self] in self?.showLauncher() }
        // First contact: no permission means a deaf session — open the
        // debug console on its Request Access button instead of silence.
        if !hasAXPermission() {
            toggleLab()
        }
    }

    private func showLauncher() {
        if launcherWindow == nil {
            let view = GioLauncherView(dismiss: { [weak self] in
                self?.launcherWindow?.close()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gio Launcher"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            launcherWindow = window
        }
        activateGio()
        launcherWindow?.makeKeyAndOrderFront(nil)
    }

    private func toggleLab() {
        if let labWindow, labWindow.isVisible {
            labWindow.close()
            return
        }
        if labWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gio Debug"
            window.contentView = NSHostingView(rootView: GioLabView())
            labWindow = window
        }
        activateGio()
        labWindow?.makeKeyAndOrderFront(nil)
    }
}

let gioDesktopDelegate = GioDesktopDelegate()
let gioDesktopApp = NSApplication.shared
gioDesktopApp.delegate = gioDesktopDelegate
gioDesktopApp.setActivationPolicy(.accessory)
gioDesktopApp.run()
