import AppKit
import Foundation
import GioCore

/// Plan §25 menu bar: workspace switcher, counts, reload, preferences, quit.
/// Actions go through IPC, so the bar never touches windows directly. State is
/// event-driven (PA-02): the session pushes a `BarSessionState` whenever a
/// reflow or command changed it (`apply`), the title follows, and the menu
/// items are rebuilt from the latest state only when the menu opens
/// (`menuNeedsUpdate`). No timer, no polling, no IPC round trip for reads.
/// Runs accessory (no Dock icon) straight from the SPM executable; the signed
/// .app bundle is 1.0 packaging work.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var latest: BarSessionState?
    /// Host-provided: the last published state; must never wait on the session queue.
    public var stateProvider: (() -> BarSessionState?)?
    /// Host-provided: summon the launcher window / the main Gio window.
    public var onOpenLauncher: (() -> Void)?
    public var onOpenMain: (() -> Void)?

    public override init() {
        super.init()
    }

    /// Build the status item. Call once from the host (this controller is no
    /// longer an app delegate — nothing calls it back automatically).
    public func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        apply(stateProvider?())
    }

    /// Pushed by the session when its state changed. Cheap: title only.
    public func apply(_ state: BarSessionState?) {
        latest = state
        statusItem?.button?.title = barTitle(state)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if let fresh = stateProvider?() {
            latest = fresh
        }
        menu.removeAllItems()
        populate(menu, state: latest)
    }

    private func populate(_ menu: NSMenu, state: BarSessionState?) {
        let open = NSMenuItem(title: "Open Gio", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        // NF-02: the dynamic stack of each display (index, windows, active
        // mark). Only the focused display's rows switch; other stacks are info.
        let stacks = state?.stacks ?? []
        if stacks.isEmpty {
            let item = NSMenuItem(title: "Workspace \(state?.workspace ?? 1)", action: nil, keyEquivalent: "")
            item.state = state == nil ? .off : .on
            item.isEnabled = false
            menu.addItem(item)
        }
        for (position, stack) in stacks.enumerated() {
            if stacks.count > 1 {
                let header = NSMenuItem(title: "Display \(position + 1)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for entry in stack.workspaces {
                let windows = entry.windows == 0 ? "empty" : (entry.windows == 1 ? "1 window" : "\(entry.windows) windows")
                let item = NSMenuItem(
                    title: "Workspace \(entry.index) · \(windows)",
                    action: #selector(switchWorkspace(_:)), keyEquivalent: ""
                )
                item.tag = entry.index
                item.target = self
                item.state = entry.isActive ? .on : .off
                item.isEnabled = stack.focused
                menu.addItem(item)
            }
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
            title: "Preferences…", action: #selector(openMain), keyEquivalent: ""
        )
        preferences.target = self
        menu.addItem(preferences)
        let launcher = NSMenuItem(
            title: "Launcher…", action: #selector(openLauncher), keyEquivalent: ""
        )
        launcher.target = self
        menu.addItem(launcher)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Gio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""
        ))
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        sendAsync(["workspace", "\(sender.tag)"])
    }

    @objc private func reloadConfig() {
        sendAsync(["reload"])
    }

    /// Fire an IPC verb off-main. The session pushes the resulting state.
    private func sendAsync(_ argv: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? sendIPCRequest(argv, socketPath: defaultSocketPath())
        }
    }

    @objc private func openLauncher() {
        onOpenLauncher?()
    }

    @objc private func openMain() {
        onOpenMain?()
    }
}

/// Open `~/.config/gio/config.toml` in the default editor, writing the
/// commented template first when it does not exist yet.
public func openConfigFileInEditor() {
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
