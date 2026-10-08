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
    /// PF-01: apps and icons scanned in the background at startup.
    private let launcherCatalog = LauncherAppCatalog()
    private lazy var launcher = LauncherPanelController(
        focusWindow: { [host] in host.focusWindow($0) }, catalog: launcherCatalog
    )
    /// WO-01: Alt+O / `gio overview`.
    private lazy var overview = WorkspaceOverviewController(
        load: { [host] completion in host.workspaceOverview(completion: completion) },
        snapshot: { [host] in host.snapshot() },
        capture: { [host] ids, completion in host.captureOverviewThumbnails(ids, completion: completion) },
        focusWindow: { [host] in host.focusWindow($0) },
        focusWorkspace: { [host] in host.focusWorkspace($0) }
    )
    private lazy var mainWindow = MainWindowController(
        model: DesktopModel(
            fetch: { [host] in host.snapshot() },
            actions: DesktopActions(
                applyEdits: { [host] in host.applyConfigEdits($0) },
                reloadConfig: { [host] in host.reloadConfig() },
                restoreAllWindows: { [host] completion in host.restoreAllWindows(completion: completion) },
                testSnapshotCapture: { [host] completion in host.testSnapshotCapture(completion: completion) },
                relaunch: { [host] in host.requestRestart() }
            )
        )
    )
    private let focusRing = FocusRingController()
    private let focusDim = FocusDimController()
    private let snapshotOverlay = SnapshotOverlayController()
    private let closeGhosts = CloseGhostOverlay()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Gio starts as an accessory app and turns regular only while the
        // main window shows; the Dock then draws the icon the system icon
        // cache holds for this bundle, which can be stale after a rebuild
        // (live: a blank placeholder, then an earlier icon). Hand it the
        // icon file inside this build instead; `NSImage(named:
        // applicationIconName)` goes through the same stale cache.
        if let icon = Bundle.main.image(forResource: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
        launcherCatalog.start()
        _ = launcher
        focusRing.start()
        host.onFocusRing = { [focusRing] state in focusRing.apply(state) }
        host.onFocusDim = { [focusDim] state in focusDim.apply(state) }
        wireSnapshotOverlay()
        if let error = host.start() {
            print("[gio] cannot start: \(error)")
            NSApplication.shared.terminate(nil)
            return
        }
        installSignalHandlers()
        let bar = MenuBarController()
        bar.onOpenLauncher = { [weak self] in self?.showLauncher(source: .menu) }
        bar.onOpenMain = { [weak self] in self?.mainWindow.show() }
        bar.stateProvider = { [host] in host.barState() }
        host.onBarState = { [weak bar] state in bar?.apply(state) }
        bar.start()
        host.requestBarState()
        self.bar = bar
        host.onSummonLauncher = { [weak self] firedAt in self?.showLauncher(source: .hotkey, requestedAt: firedAt) }
        host.onToggleOverview = { [weak self] in self?.overview.toggle() }
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
        snapshotOverlay.stop()
        closeGhosts.stop()
        focusRing.stop()
        focusDim.stop()
    }

    /// SM-04: the session queue drives the overlay through hooks that hop to
    /// the main thread; the overlay reports landed springs back to the host.
    private func wireSnapshotOverlay() {
        let overlay = snapshotOverlay
        overlay.start()
        overlay.onFlightFinished = { [host] token in host.snapshotLayersFinished(token) }
        overlay.onFlightAborted = { [host] _, reason in host.snapshotFlightAborted(reason) }
        // The tap callback runs on the main run loop; never assume it blindly.
        host.overlayAbortForMouseDown = {
            Thread.isMainThread ? MainActor.assumeIsolated { overlay.abortForMouseDown() } : false
        }
        host.overlayWallpapers = overlay.wallpapers
        host.overlayBegin = { [host] token, spring, flights in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // No wallpaper yet: nothing shown, settle right away.
                    if !overlay.begin(token: token, spring: spring, flights: flights) {
                        host.snapshotLayersFinished(token)
                    }
                }
            }
        }
        host.overlayRetarget = { token, targets, flights in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { overlay.retarget(token: token, targets: targets, adding: flights) }
            }
        }
        host.overlayEnd = { fadeOut in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { overlay.end(fadeOut: fadeOut) }
            }
        }
        // NA-03: the close ghost, a window-sized layer that removes itself.
        let ghosts = closeGhosts
        host.ghostShow = { token, image, frame, duration, shrink in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ghosts.show(token: token, image: image, frame: frame, duration: duration, shrink: shrink)
                }
            }
        }
        host.ghostRemove = { token in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ghosts.remove(token: token) }
            }
        }
    }

    /// `gio restart`: restore windows and release the socket and lock, start a
    /// fresh instance (it waits for the lock if needed), then exit.
    private func restartSession() {
        host.shutdown()
        snapshotOverlay.stop()
        closeGhosts.stop()
        focusRing.stop()
        focusDim.stop()
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

    /// DD-05: a Spotlight-like panel that takes key without activating
    /// Gio, so the main window never jumps forward. Alt+Space again closes it
    /// (FI-09: the toggle reads the panel itself and every step is logged).
    private func showLauncher(source: LauncherSummonSource, requestedAt: TimeInterval? = nil) {
        // One published snapshot read (never a wait on the session queue).
        let facts = host.snapshot().facts
        launcher.summon(
            source: source, requestedAt: requestedAt,
            windows: { facts?.windows ?? [] },
            workspaces: { launcherWorkspaceEntries(from: facts) },
            apps: { [launcherCatalog] in launcherCatalog.apps }
        )
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
