import AppKit
import SwiftUI
import XCTest

/// Renders SwiftUI views to PNG in light and dark mode for visual review.
/// Writes only when `GIO_SNAPSHOT_DIR` is set; otherwise the calling test is
/// skipped so CI and ordinary `swift test` runs never touch the disk.
@MainActor
enum SnapshotHarness {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["GIO_SNAPSHOT_DIR"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func requireDirectory() throws -> URL {
        guard let directory else {
            throw XCTSkip("GIO_SNAPSHOT_DIR not set; snapshots are opt-in")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes `<name>-light.png` and `<name>-dark.png` and returns their paths.
    @discardableResult
    static func render<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) throws -> [URL] {
        let directory = try requireDirectory()
        let content = view()
        var written: [URL] = []
        for (suffix, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            let appearanceObject = NSAppearance(named: appearance)!
            var failure: Error?
            // Dynamic NSColors resolve against the current drawing appearance,
            // not the SwiftUI environment, so render inside the appearance.
            appearanceObject.performAsCurrentDrawingAppearance {
                let framed = content
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                let renderer = ImageRenderer(content: framed)
                renderer.scale = 2
                guard let image = renderer.cgImage else {
                    failure = SnapshotError.renderFailed(name)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    failure = SnapshotError.renderFailed(name)
                    return
                }
                do {
                    try data.write(to: url)
                    written.append(url)
                } catch {
                    failure = error
                }
            }
            if let failure {
                throw failure
            }
        }
        return written
    }
}

enum SnapshotError: Error {
    case renderFailed(String)
}
