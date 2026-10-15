import AppKit
import Foundation
import GioCore

/// PF-01: when the launcher's app list is scanned. A notification burst
/// costs one scan after `debounce`; a request while a scan runs costs one
/// more scan after it, never two at once. Pure, so it is tested.
public struct LauncherCatalogRefresh: Equatable, Sendable {
    /// Quiet time after the last request before rescanning.
    public static let debounce: TimeInterval = 0.5
    /// A summon older than this since the last scan asks for a refresh in
    /// the background (catches apps installed without launching them).
    public static let staleAfter: TimeInterval = 120

    private var generation = 0
    public private(set) var isScanning = false
    private var pendingAfterScan = false
    private var lastScanAt: TimeInterval?

    public init() {}

    /// A refresh was asked for; fire the returned token after `debounce`.
    public mutating func request() -> Int {
        generation += 1
        return generation
    }

    /// The debounce elapsed. True when the scan starts now. A superseded
    /// token does nothing; a current one during a scan defers to its end.
    public mutating func fire(_ token: Int, at now: TimeInterval) -> Bool {
        guard token == generation else {
            return false
        }
        if isScanning {
            pendingAfterScan = true
            return false
        }
        isScanning = true
        return true
    }

    /// A scan with no request (startup). False when one already runs.
    public mutating func beginScan() -> Bool {
        guard !isScanning else {
            return false
        }
        isScanning = true
        return true
    }

    /// The scan finished. True when another must start right away.
    public mutating func finishScan(at now: TimeInterval) -> Bool {
        lastScanAt = now
        if pendingAfterScan {
            pendingAfterScan = false
            return true
        }
        isScanning = false
        return false
    }

    public func isStale(at now: TimeInterval) -> Bool {
        guard let lastScanAt else {
            return true
        }
        return now - lastScanAt > Self.staleAfter
    }
}

/// One background scan's result; images are only read on the main thread
/// once handed over.
private struct LauncherScanResult: @unchecked Sendable {
    let apps: [LauncherEntry]
    let icons: [String: NSImage]
    /// When each bundle's icon was drawn from (its Info.plist's date).
    let stamps: [String: TimeInterval]
    let drawn: Int
}

/// PF-T (2026-10-15 profile: every app launch redrew the icon of every
/// installed app, 8 % of Gio's CPU while in use): the bundles of `found`
/// (path to its Info.plist's modification time) whose icon must be drawn,
/// sorted: new ones and those changed since `drawn`. The others keep the
/// icon they have.
public func launcherIconsToDraw(found: [String: TimeInterval], drawn: [String: TimeInterval]) -> [String] {
    found.filter { drawn[$0.key] != $0.value }.keys.sorted()
}

/// The modification time of a bundle's Info.plist (an update rewrites it),
/// else of the bundle itself; 0 when neither can be read.
private func launcherBundleStamp(_ path: String) -> TimeInterval {
    let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
    for candidate in [plist, path] {
        if let date = (try? FileManager.default.attributesOfItem(atPath: candidate))?[.modificationDate] as? Date {
            return date.timeIntervalSince1970
        }
    }
    return 0
}

/// PF-01: the launcher's app list and icons, built off the main thread at
/// startup and refreshed (debounced) when apps launch or a summon finds it
/// stale. Summoning reads what is cached and never scans: rows without a
/// cached icon show their fallback symbol until the scan lands.
@MainActor
public final class LauncherAppCatalog {
    /// Icons are drawn once at this size (points, 2x pixels).
    public static let iconSide: CGFloat = 30

    public private(set) var apps: [LauncherEntry] = []
    /// Called on the main thread after a scan landed.
    public var onChange: (() -> Void)?

    private var icons: [String: NSImage] = [:]
    private var iconStamps: [String: TimeInterval] = [:]
    private var appIcons: [String: NSImage] = [:]
    private var refresh = LauncherCatalogRefresh()
    private let directories: [String]
    private let now: () -> TimeInterval
    private var observers: [NSObjectProtocol] = []

    public init(
        directories: [String] = defaultApplicationDirectories(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.directories = directories
        self.now = now
    }

    /// Scan now in the background and refresh when an app launches.
    public func start() {
        if refresh.beginScan() {
            scan(reason: "startup")
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRefresh() }
        })
    }

    public func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Debounced background rescan.
    public func requestRefresh() {
        let token = refresh.request()
        DispatchQueue.main.asyncAfter(deadline: .now() + LauncherCatalogRefresh.debounce) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refresh.fire(token, at: self.now()) else {
                    return
                }
                self.scan(reason: "refresh")
            }
        }
    }

    /// A summon: rescan in the background when the list is old.
    public func refreshIfStale() {
        if refresh.isStale(at: now()) && !refresh.isScanning {
            requestRefresh()
        }
    }

    /// The cached icon of an entry; never scans or draws a bundle icon.
    public func icon(for entry: LauncherEntry) -> NSImage? {
        switch entry {
        case .app(_, _, let path):
            return icons[path]
        case .window(_, let application, _, _):
            if let cached = appIcons[application] {
                return cached
            }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == application })
            else {
                return nil
            }
            let image = app.bundleURL.flatMap { icons[$0.path] }
                ?? app.icon.map { scaledLauncherIcon($0, side: Self.iconSide) }
            appIcons[application] = image
            return image
        case .gioCommand, .shellCommand, .workspace:
            return nil
        }
    }

    private func scan(reason: String) {
        let directories = directories
        let started = now()
        let side = Self.iconSide
        let cached = LauncherScanResult(apps: [], icons: icons, stamps: iconStamps, drawn: 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = scanApplications(directories: directories)
            var stamps: [String: TimeInterval] = [:]
            for case .app(_, _, let path) in apps {
                stamps[path] = launcherBundleStamp(path)
            }
            let toDraw = Set(launcherIconsToDraw(found: stamps, drawn: cached.stamps))
            var icons: [String: NSImage] = [:]
            for path in stamps.keys {
                if !toDraw.contains(path), let icon = cached.icons[path] {
                    icons[path] = icon
                } else {
                    icons[path] = scaledLauncherIcon(NSWorkspace.shared.icon(forFile: path), side: side)
                }
            }
            let result = LauncherScanResult(apps: apps, icons: icons, stamps: stamps, drawn: toDraw.count)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.land(result, started: started, reason: reason) }
            }
        }
    }

    private func land(_ result: LauncherScanResult, started: TimeInterval, reason: String) {
        apps = result.apps
        icons = result.icons
        iconStamps = result.stamps
        appIcons.removeAll()
        let finished = now()
        GioLog.record(
            .info,
            "launcher appsReady ms=\(Int(((finished - started) * 1000).rounded())) apps=\(result.apps.count)"
                + " icons=\(result.icons.count) drawn=\(result.drawn) reason=\(reason)"
        )
        if refresh.finishScan(at: finished) {
            scan(reason: "refresh")
        }
        onChange?()
    }
}

/// Draw an icon once into a bitmap of `side` points at 2x, so rows never
/// rasterize a full-size bundle icon. Safe off the main thread (own context).
public func scaledLauncherIcon(_ image: NSImage, side: CGFloat) -> NSImage {
    let pixels = Int(side * 2)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep)
    else {
        return image
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: side, height: side)
    let scaled = NSImage(size: rep.size)
    scaled.addRepresentation(rep)
    return scaled
}
