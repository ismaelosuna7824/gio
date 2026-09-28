import AppKit
import Foundation
import GioCore

/// Plan §25 menu bar, first cut: workspace switcher, counts, reload,
/// preferences, quit — all through IPC, so the bar never touches windows
/// directly. Polls `status` every few seconds until the daemon pushes
/// events; shows an honest `Gio` with everything disabled when no session
/// answers. Runs accessory (no Dock icon) straight from the SPM executable;
/// the signed .app bundle is 1.0 packaging work.
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    /// Host-provided: summon the launcher window / debug console.
    public var onOpenLauncher: (() -> Void)?
    public var onOpenDebug: (() -> Void)?

    public override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Gio"
        statusItem.menu = buildMenu(state: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 1
        refresh()
    }

    private func query() -> BarSessionState? {
        guard let response = try? sendIPCRequest(["status"], socketPath: defaultSocketPath()),
              response.ok,
              let output = response.output
        else {
            return nil
        }
        return parseBarStatus(output)
    }

    private func refresh() {
        let state = query()
        statusItem.button?.title = barTitle(state)
        statusItem.menu = buildMenu(state: state)
    }

    private func buildMenu(state: BarSessionState?) -> NSMenu {
        let menu = NSMenu()
        for number in WorkspaceManager.range {
            let item = NSMenuItem(
                title: "Workspace \(number)", action: #selector(switchWorkspace(_:)), keyEquivalent: ""
            )
            item.tag = number
            item.target = self
            item.state = state?.workspace == number ? .on : .off
            item.isEnabled = state != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let info = NSMenuItem(
            title: state.map { "\($0.windows) windows · \($0.columns) columns" } ?? "no session",
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        menu.addItem(info)
        let reload = NSMenuItem(
            title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""
        )
        reload.target = self
        reload.isEnabled = state != nil
        menu.addItem(reload)
        let preferences = NSMenuItem(
            title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ""
        )
        preferences.target = self
        menu.addItem(preferences)
        let launcher = NSMenuItem(
            title: "Launcher…", action: #selector(openLauncher), keyEquivalent: ""
        )
        launcher.target = self
        menu.addItem(launcher)
        let debug = NSMenuItem(
            title: "Debug Console", action: #selector(openDebug), keyEquivalent: ""
        )
        debug.target = self
        menu.addItem(debug)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit GioBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""
        ))
        return menu
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        _ = try? sendIPCRequest(["workspace", "\(sender.tag)"], socketPath: defaultSocketPath())
        refresh()
    }

    @objc private func reloadConfig() {
        _ = try? sendIPCRequest(["reload"], socketPath: defaultSocketPath())
        refresh()
    }

    @objc private func openPreferences() {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml"
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? defaultConfigTemplate().write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openLauncher() {
        onOpenLauncher?()
    }

    @objc private func openDebug() {
        onOpenDebug?()
    }
}
