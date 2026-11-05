import Foundation

/// SB-01: Install Command Line Tool links `~/.local/bin/gio` to the running
/// app's own executable, which acts as the `gio` client when started under
/// that name (`isGioCLIInvocation`). An in-place update replaces the bundle
/// at the same path, so the link keeps working.

/// What is at the link path now.
public enum CLIToolLinkState: Equatable, Sendable {
    case missing
    case symlink(to: String)
    /// A regular file, a directory or anything else that is not a link.
    case otherFile
}

public enum CLIToolInstallPlan: Equatable, Sendable {
    case create(link: String, target: String)
    /// An older Gio link (into a Gio.app, or the FI-09 link to a built GioCLI).
    case replace(link: String, previous: String, target: String)
    case alreadyInstalled(link: String)
    case refuse(reason: String)
}

public enum CLIToolInstallOutcome: Equatable, Sendable {
    case installed(link: String, target: String, replaced: String?)
    case alreadyInstalled(link: String)
    case refused(String)
    case failed(String)
}

/// The executable to link: the bundle's own, only when running from an app
/// bundle (`swift run` has none worth linking).
public func cliToolTarget(bundlePath: String, executablePath: String?) -> String? {
    guard URL(fileURLWithPath: bundlePath).pathExtension == "app", let executablePath else {
        return nil
    }
    return executablePath
}

public func cliToolLinkPath(home: String) -> String {
    "\(home)/.local/bin/gio"
}

/// A link Gio made earlier, safe to replace.
func isGioLink(_ destination: String) -> Bool {
    destination.contains("/Gio.app/") || URL(fileURLWithPath: destination).lastPathComponent == "GioCLI"
}

public func planCLIToolInstall(target: String?, home: String, existing: CLIToolLinkState) -> CLIToolInstallPlan {
    let link = cliToolLinkPath(home: home)
    guard let target else {
        return .refuse(reason: "Open Gio.app to install the command line tool (this copy is not an app bundle).")
    }
    switch existing {
    case .missing:
        return .create(link: link, target: target)
    case .symlink(let destination) where destination == target:
        return .alreadyInstalled(link: link)
    case .symlink(let destination) where isGioLink(destination):
        return .replace(link: link, previous: destination, target: target)
    case .symlink(let destination):
        return .refuse(reason: "~/.local/bin/gio links to \(destination), not to Gio. Remove it, then try again.")
    case .otherFile:
        return .refuse(reason: "~/.local/bin/gio exists and is not a link to Gio. Remove it, then try again.")
    }
}

/// The file system writes the install needs (a fake in tests).
public protocol CLIToolFileSystem {
    func linkState(at path: String) -> CLIToolLinkState
    func createDirectory(_ path: String) throws
    func removeItem(_ path: String) throws
    func createSymlink(at path: String, to destination: String) throws
}

public struct LiveCLIToolFileSystem: CLIToolFileSystem {
    public init() {}

    public func linkState(at path: String) -> CLIToolLinkState {
        let files = FileManager.default
        if let destination = try? files.destinationOfSymbolicLink(atPath: path) {
            return .symlink(to: destination)
        }
        return files.fileExists(atPath: path) ? .otherFile : .missing
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func removeItem(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func createSymlink(at path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }
}

public func installCLITool(target: String?, home: String, fileSystem: CLIToolFileSystem) -> CLIToolInstallOutcome {
    let link = cliToolLinkPath(home: home)
    let plan = planCLIToolInstall(target: target, home: home, existing: fileSystem.linkState(at: link))
    do {
        switch plan {
        case .refuse(let reason):
            return .refused(reason)
        case .alreadyInstalled(let link):
            return .alreadyInstalled(link: link)
        case .create(let link, let target):
            try fileSystem.createDirectory((link as NSString).deletingLastPathComponent)
            try fileSystem.createSymlink(at: link, to: target)
            return .installed(link: link, target: target, replaced: nil)
        case .replace(let link, let previous, let target):
            try fileSystem.removeItem(link)
            try fileSystem.createSymlink(at: link, to: target)
            return .installed(link: link, target: target, replaced: previous)
        }
    } catch {
        return .failed(error.localizedDescription)
    }
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
