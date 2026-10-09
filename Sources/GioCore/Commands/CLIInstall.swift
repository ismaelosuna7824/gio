import Foundation

/// FI-09: how to put the `gio` command on PATH. The Xcode app does not ship
/// the SwiftPM `GioCLI` binary, so the plan links a built one from the
/// source checkout into `~/.local/bin/gio`, or gives the shell command that
/// builds and links it.
public struct GioCommandInstallPlan: Equatable, Sendable {
    /// A built GioCLI to link now, when one exists.
    public let binary: String?
    public let linkPath: String
    /// A copyable command that does the whole install.
    public let shellCommand: String
}

/// The checkout root of a file under `<root>/Sources/<Module>/<File>.swift`.
public func gioSourceRoot(fromSourceFile path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    let module = url.deletingLastPathComponent()
    let sources = module.deletingLastPathComponent()
    guard path.hasPrefix("/"), sources.lastPathComponent == "Sources" else {
        return nil
    }
    // Keep the root's own spelling (a trailing space survives).
    let suffix = "/Sources/\(module.lastPathComponent)/\(url.lastPathComponent)"
    guard path.hasSuffix(suffix) else {
        return nil
    }
    return String(path.dropLast(suffix.count))
}

public func planGioCommandInstall(
    sourceRoot: String?, home: String, fileExists: (String) -> Bool
) -> GioCommandInstallPlan {
    let linkPath = "\(home)/.local/bin/gio"
    let link = "mkdir -p ~/.local/bin && ln -sf"
    guard let root = sourceRoot else {
        let placeholder = "<path-to-gio-repo>"
        return GioCommandInstallPlan(
            binary: nil, linkPath: linkPath,
            shellCommand: "cd \(placeholder) && swift build --product GioCLI && \(link) \(placeholder)/.build/debug/GioCLI ~/.local/bin/gio"
        )
    }
    let candidates = ["\(root)/.build/release/GioCLI", "\(root)/.build/debug/GioCLI"]
    if let binary = candidates.first(where: fileExists) {
        return GioCommandInstallPlan(
            binary: binary, linkPath: linkPath,
            shellCommand: "\(link) \(shellQuoted(binary)) ~/.local/bin/gio"
        )
    }
    return GioCommandInstallPlan(
        binary: nil, linkPath: linkPath,
        shellCommand: "cd \(shellQuoted(root)) && swift build --product GioCLI && \(link) \(shellQuoted(candidates[1])) ~/.local/bin/gio"
    )
}

/// Whether `~/.local/bin` is on a PATH value (so `gio` resolves after linking).
public func localBinOnPath(_ path: String, home: String) -> Bool {
    let target = "\(home)/.local/bin"
    return path.split(separator: ":").contains { entry in
        var entry = String(entry)
        while entry.count > 1, entry.hasSuffix("/") {
            entry.removeLast()
        }
        return entry == target
    }
}

/// Single-quoted for `/bin/sh`: nothing inside is expanded (also used by the
/// update helper script, UP-05).
public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
