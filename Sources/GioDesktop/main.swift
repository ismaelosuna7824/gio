import AppKit
import Foundation
import GioCore
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
    private lazy var launcherApps = scanApplications(directories: defaultApplicationDirectories())
    private lazy var mainWindow = MainWindowController(
        model: DesktopModel(
            fetch: { [host] in host.snapshot() },
            actions: DesktopActions(
                applyEdits: { [host] in host.applyConfigEdits($0) },
                reloadConfig: { [host] in host.reloadConfig() },
                restoreAllWindows: { [host] completion in host.restoreAllWindows(completion: completion) }
            )
        )
    )
    private let focusRing = FocusRingController()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        focusRing.start()
        host.onFocusRing = { [focusRing] state in focusRing.apply(state) }
        if let error = host.start() {
            print("[gio] cannot start: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        installSignalHandlers()
        let bar = MenuBarController()
        bar.onOpenLauncher = { [weak self] in self?.showLauncher() }
        bar.onOpenMain = { [weak self] in self?.mainWindow.show() }
        bar.stateProvider = { [host] in host.barState() }
        host.onBarState = { [weak bar] state in bar?.apply(state) }
        bar.start()
        host.requestBarState()
        self.bar = bar
        host.onSummonLauncher = { [weak self] in self?.showLauncher() }
        host.onRestart = { [weak self] in self?.restartSession() }
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
        focusRing.stop()
    }

    /// `gio restart`: restore windows and release the socket and lock, start a
    /// fresh instance (it waits for the lock if needed), then exit.
    private func restartSession() {
        host.shutdown()
        focusRing.stop()
        relaunchGio { NSApplication.shared.terminate(nil) }
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
        // A fresh view per summon: the window list is current and the query empty.
        let view = GioLauncherView(
            windows: host.snapshot().facts?.windows ?? [],
            focusWindow: { [host] in host.focusWindow($0) },
            apps: launcherApps,
            dismiss: { [weak self] in self?.launcherWindow?.close() }
        )
        if launcherWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gio Launcher"
            window.center()
            launcherWindow = window
        }
        launcherWindow?.contentView = NSHostingView(rootView: view)
        activateGio()
        launcherWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Start a new instance of this app: its bundle when packaged, else the bare
/// executable (`swift run`). `done` runs once the request is handed off.
@MainActor
func relaunchGio(done: @escaping @MainActor () -> Void) {
    let bundleURL = Bundle.main.bundleURL
    if bundleURL.pathExtension == "app" {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [relaunchArgument]
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                print("[gio] relaunch failed: \(error)")
            }
            DispatchQueue.main.async { done() }
        }
        return
    }
    if let executable = Bundle.main.executableURL {
        let process = Process()
        process.executableURL = executable
        process.arguments = [relaunchArgument]
        do {
            try process.run()
        } catch {
            print("[gio] relaunch failed: \(error)")
        }
    }
    done()
}

// Guardian mode (spawned by Gio itself): no app, no Dock icon, no lock, no IPC.
if let guardianParent = parseGuardianLaunch(arguments: CommandLine.arguments) {
    exit(runGuardianProcess(parentPID: guardianParent))
}

let gioDesktopDelegate = GioDesktopDelegate()
let gioDesktopApp = NSApplication.shared
gioDesktopApp.delegate = gioDesktopDelegate
gioDesktopApp.setActivationPolicy(.accessory)
gioDesktopApp.run()
