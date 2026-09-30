import AppKit
import Foundation
import GioCore

/// NW-03 app picker sources: running apps plus `.app` bundles installed in
/// the usual folders, identified by bundle id.
public struct AppCandidate: Equatable, Sendable, Identifiable {
    public let name: String
    public let bundleID: String
    public var path: String?
    public var isRunning: Bool

    public init(name: String, bundleID: String, path: String? = nil, isRunning: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.isRunning = isRunning
    }

    public var id: String { bundleID }

    public var assignment: WorkspaceAppAssignment {
        WorkspaceAppAssignment(app: name, bundleID: bundleID)
    }
}

/// `/Applications`, `/System/Applications` and `~/Applications`.
public func installedAppDirectories(home: String) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true),
    ]
}

/// Bundle id and name from an app bundle's Info.plist; nil without an id.
/// The name is the display name, else the bundle name, else the file name.
public func readAppBundle(at url: URL) -> AppCandidate? {
    let plistURL = url.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
    else {
        return nil
    }
    let fileName = url.deletingPathExtension().lastPathComponent
    let name = [plist["CFBundleDisplayName"], plist["CFBundleName"]]
        .compactMap { $0 as? String }
        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? fileName
    return AppCandidate(name: name, bundleID: bundleID, path: url.path)
}

/// `.app` bundles directly in each directory and one folder below
/// (`/Applications/Utilities`), deduplicated by bundle id (first wins) and
/// sorted by name. Missing directories are skipped.
public func scanInstalledApps(in directories: [URL], fileManager: FileManager = .default) -> [AppCandidate] {
    var seen = Set<String>()
    var found: [AppCandidate] = []

    func entries(_ directory: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func take(_ url: URL) {
        guard let app = readAppBundle(at: url), seen.insert(app.bundleID).inserted else {
            return
        }
        found.append(app)
    }

    for directory in directories {
        for entry in entries(directory) {
            if entry.pathExtension == "app" {
                take(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for nested in entries(entry) where nested.pathExtension == "app" {
                    take(nested)
                }
            }
        }
    }
    return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Running apps first, then installed ones not running, each by name. A
/// running app picks up its installed path.
public func mergeAppCandidates(running: [AppCandidate], installed: [AppCandidate]) -> [AppCandidate] {
    let paths = Dictionary(installed.map { ($0.bundleID, $0.path) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    let byName: (AppCandidate, AppCandidate) -> Bool = {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    let live = running.sorted(by: byName).compactMap { app -> AppCandidate? in
        guard seen.insert(app.bundleID).inserted else {
            return nil
        }
        var merged = app
        merged.isRunning = true
        merged.path = app.path ?? paths[app.bundleID] ?? nil
        return merged
    }
    let rest = installed.filter { seen.insert($0.bundleID).inserted }.sorted(by: byName)
    return live + rest
}

/// Candidates whose name or bundle id contains `query`.
public func filterAppCandidates(_ apps: [AppCandidate], query: String) -> [AppCandidate] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else {
        return apps
    }
    return apps.filter { $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle) }
}

/// Installed apps, scanned once off the main thread and cached for the
/// app's lifetime; running apps are read fresh each time the picker opens.
@MainActor
final class InstalledAppCatalog: ObservableObject {
    static let shared = InstalledAppCatalog()

    @Published private(set) var installed: [AppCandidate] = []
    @Published private(set) var isLoading = false
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded, !isLoading else {
            return
        }
        isLoading = true
        let directories = installedAppDirectories(home: NSHomeDirectory())
        Task.detached(priority: .utility) {
            let apps = scanInstalledApps(in: directories)
            await MainActor.run {
                self.installed = apps
                self.isLoading = false
                self.loaded = true
            }
        }
    }

    /// Regular (Dock) apps running now, Gio excluded.
    static func runningApps() -> [AppCandidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != own,
                  let bundleID = app.bundleIdentifier, let name = app.localizedName
            else {
                return nil
            }
            return AppCandidate(name: name, bundleID: bundleID, path: app.bundleURL?.path, isRunning: true)
        }
    }
}
