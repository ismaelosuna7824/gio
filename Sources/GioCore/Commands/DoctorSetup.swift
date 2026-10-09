import Foundation

/// Plan §28 Omarchy-style operations. `doctor` diagnoses, `setup` guides,
/// `update`/`uninstall` are version-aware and honest pre-1.0: no releases
/// are published and no app is installed yet, so they report instead of
/// pretending. All facts render explicitly — unknown stays unknown.
public func runDoctor(session: inout CommandSession) -> String {
    var lines = ["Gio doctor (\(gioVersion))"]
    switch session.permissionGranted {
    case .some(true):
        lines.append("[ok] accessibility: granted")
    case .some(false):
        lines.append("[fail] accessibility: missing — grant via GioLab Request Access")
    case .none:
        lines.append("[??] accessibility: unknown in-process")
    }
    let (_, messages) = loadGioConfig(at: session.configPath)
    if messages.isEmpty {
        lines.append("[ok] configuration: valid")
    } else {
        lines.append("[fail] configuration: " + messages.joined(separator: "; "))
    }
    lines.append("[ok] version: \(gioVersion)")
    do {
        let response = try sendIPCRequest(["status"], socketPath: defaultSocketPath())
        if response.ok {
            lines.append("[ok] ipc: session answering")
        } else {
            lines.append("[fail] ipc: session errored")
        }
    } catch {
        lines.append("[fail] ipc: no session (start the daemon)")
    }
    if let count = session.displayCount {
        lines.append("[ok] displays: \(count)")
    } else {
        lines.append("[??] displays: unknown in-process")
    }
    if session.recentErrors.isEmpty {
        lines.append("[ok] recent errors: none recorded")
    } else {
        lines.append("[fail] recent errors: " + session.recentErrors.prefix(3).joined(separator: "; "))
    }
    return lines.joined(separator: "\n")
}

public func runSetup(session: inout CommandSession) -> String {
    var lines = ["Gio setup (\(gioVersion))"]
    switch session.permissionGranted {
    case .some(true):
        lines.append("[ok] accessibility: granted")
    default:
        lines.append("[--] accessibility: grant via GioLab Request Access, then re-run setup")
    }
    let path = session.configPath
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml")
    if FileManager.default.fileExists(atPath: path) {
        let (_, messages) = loadGioConfig(at: session.configPath)
        session.config = loadGioConfig(at: session.configPath).config
        if messages.isEmpty {
            lines.append("[ok] configuration: \(path)")
        } else {
            lines.append("[--] configuration: \(messages.joined(separator: "; "))")
        }
    } else {
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try defaultConfigTemplate().write(toFile: path, atomically: true, encoding: .utf8)
            let (config, messages) = loadGioConfig(at: session.configPath)
            session.config = config
            lines.append("[ok] configuration: template written to \(path)" + (messages.isEmpty ? "" : " (\(messages.joined(separator: "; ")))"))
        } catch {
            lines.append("[fail] configuration: cannot write \(path): \(error)")
        }
    }
    let bindings = session.config.makeDispatcher().bindingCount
    lines.append("[ok] hotkeys: \(bindings) bindings (defaults plus config)")
    lines.append(
        "[ok] themes: builtin \(builtinThemes().map(\.name).joined(separator: ", ")) (user dir ~/.config/gio/themes/)"
    )
    lines.append("[--] bar/launcher: run via Xcode schemes GioBar/GioLauncher (signed packaging at 1.0)")
    lines.append("[--] autostart: not installed (no stable binary yet)")
    return lines.joined(separator: "\n")
}

/// UP-06: the Gio app answers `gio update` itself (its IPC server hands the
/// request to the updater before dispatch); this is the answer of a session
/// without one.
public func runUpdate(install: Bool = false) -> String {
    "Gio \(gioVersion): this session cannot \(install ? "install" : "check for") updates; open the Gio app"
}

public func runUninstall() -> String {
    // Refuse against a live session: the lock proves nobody holds it.
    let lock = SingleInstanceLock()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let socket = home + "/.config/gio/gio.sock"
    let lockPath = home + "/.config/gio/gio.lock"
    var lines = ["Gio uninstall (\(gioVersion))"]
    guard lock.acquire(path: lockPath) else {
        lines.append("refusing: a Gio session is running (quit it first)")
        lines.append("kept: configuration, themes, everything")
        return lines.joined(separator: "\n")
    }
    defer {
        lock.release()
    }
    var removed: [String] = []
    for path in [socket, lockPath] {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            removed.append((path as NSString).lastPathComponent)
        }
    }
    lines.append(removed.isEmpty ? "removed: nothing (already absent)" : "removed: \(removed.joined(separator: ", "))")
    lines.append("kept: ~/.config/gio/config.toml, ~/.config/gio/themes/ (your data)")
    return lines.joined(separator: "\n")
}
