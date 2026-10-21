import AppKit
import Foundation

/// PA-22: the launcher's drawn icons on disk, so a launch draws only the
/// bundles that changed (`launcherIconsToDraw`) instead of all of them. One
/// binary property list: the icon side it was drawn at and, per bundle path,
/// the Info.plist date it was drawn from and the PNG. Regenerable, so it
/// lives in Caches; a missing, unreadable or other-size file reads as empty.
/// Safe off the main thread (no shared state).
public struct LauncherIconStore: Sendable {
    private static let version = 1
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Caches/<bundle id>/launcher-icons.plist`.
    public static func userCache() -> LauncherIconStore? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = Bundle.main.bundleIdentifier ?? "gio"
        return LauncherIconStore(url: caches.appendingPathComponent(folder).appendingPathComponent("launcher-icons.plist"))
    }

    public func load(side: CGFloat) -> (icons: [String: NSImage], stamps: [String: TimeInterval]) {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["version"] as? Int == Self.version,
              root["side"] as? Double == Double(side),
              let entries = root["icons"] as? [String: [String: Any]]
        else {
            return ([:], [:])
        }
        var icons: [String: NSImage] = [:]
        var stamps: [String: TimeInterval] = [:]
        for (path, entry) in entries {
            guard let stamp = entry["stamp"] as? Double, let png = entry["png"] as? Data,
                  let rep = NSBitmapImageRep(data: png)
            else {
                continue
            }
            rep.size = NSSize(width: side, height: side)
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            icons[path] = image
            stamps[path] = stamp
        }
        return (icons, stamps)
    }

    /// Replaces the file atomically; an icon without a bitmap is left out
    /// (it is drawn again next time).
    public func save(icons: [String: NSImage], stamps: [String: TimeInterval], side: CGFloat) {
        var entries: [String: [String: Any]] = [:]
        for (path, image) in icons {
            guard let stamp = stamps[path],
                  let rep = image.representations.first as? NSBitmapImageRep,
                  let png = rep.representation(using: .png, properties: [:])
            else {
                continue
            }
            entries[path] = ["stamp": stamp, "png": png]
        }
        let root: [String: Any] = ["version": Self.version, "side": Double(side), "icons": entries]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
