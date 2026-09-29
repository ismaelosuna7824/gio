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

/// The unified Gio app: menu bar, main window and launcher over one
/// session host (config, lock, IPC server, registry, workspaces, displays,
/// actuator, event intake, hotkey tap). One process; activation policy is
/// regular while the main window is visible and accessory otherwise. The `gio` CLI talks to it over IPC; the signed
/// .app bundle is 1.0 packaging work.
@MainActor
final class GioDesktopDelegate: NSObject, NSApplicationDelegate {
    private let host = SessionHost()
    private var bar: MenuBarController?
    private var launcherWindow: NSWindow?
    private lazy var mainWindow = MainWindowController(
        model: DesktopModel(
            fetch: { [host] in host.snapshot() },
            actions: DesktopActions(applyEdits: { [host] in host.applyConfigEdits($0) })
        )
    )
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = host.start() {
            print("[gio] cannot start: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        installSignalHandlers()
        let bar = MenuBarController()
        bar.onOpenLauncher = { [weak self] in self?.showLauncher() }
        bar.onOpenMain = { [weak self] in self?.mainWindow.show() }
        bar.start()
        self.bar = bar
        host.onSummonLauncher = { [weak self] in self?.showLauncher() }
        mainWindow.installMainMenu()
        // The window opens on launch (Dock icon while visible); closing it
        // hides it and Gio keeps running from the menu bar.
        mainWindow.show()
    }

    /// Dock icon click while the window is hidden (policy is regular only
    /// while it is visible, but Cmd+Tab / Dock can race a hide).
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindow.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.shutdown()
    }

    /// SIGTERM/SIGINT/SIGHUP: default handlers would kill the process with
    /// windows still parked. Ignore them and route through the terminate path.
    func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.host.shutdown()
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
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
}

let gioDesktopDelegate = GioDesktopDelegate()
let gioDesktopApp = NSApplication.shared
gioDesktopApp.delegate = gioDesktopDelegate
gioDesktopApp.setActivationPolicy(.accessory)
gioDesktopApp.run()
