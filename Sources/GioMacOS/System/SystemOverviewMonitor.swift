import AppKit
import CoreGraphics
import GioCore

/// WC-18: notices while macOS shows its own overview of the windows (Mission
/// Control, App Exposé) so Gio's focus ring and dim step aside.
///
/// macOS 27 stopped posting the Dock's `AXExpose*` notifications, and there is
/// no public notification for the overview, so this is a window-list poll on a
/// utility queue: one `CGWindowListCopyWindowInfo` every half second with
/// leeway, which measured under 0.1 % CPU, and a main-thread callback only when
/// the answer changes. The decision itself is `systemOverviewShowing` in
/// GioCore (pure, tested).
public final class SystemOverviewMonitor: @unchecked Sendable {
    private let screens: () -> [CGRect]
    private let onChange: (Bool) -> Void
    private let queue = DispatchQueue(label: "gio.system-overview", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last = false
    private var stopped = false

    public init(screens: @escaping () -> [CGRect], onChange: @escaping (Bool) -> Void) {
        self.screens = screens
        self.onChange = onChange
    }

    /// Main thread, once. The first check runs at once so a Gio that launches
    /// over the overview does not draw a frame.
    public func start() {
        guard timer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }

    private func check() {
        guard !stopped else {
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownerKey = kCGWindowOwnerName as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String
        var surfaces: [OnScreenSurface] = []
        surfaces.reserveCapacity(list.count)
        for raw in list {
            guard let owner = raw[ownerKey] as? String, let level = raw[layerKey] as? Int else {
                continue
            }
            // Only the WindowManager's shield matters; skip the rest early.
            guard owner == "WindowManager", level == 19 else {
                continue
            }
            let bounds = (raw[boundsKey] as? [String: NSNumber]).map { box in
                CGRect(
                    x: box["X"]?.doubleValue ?? 0, y: box["Y"]?.doubleValue ?? 0,
                    width: box["Width"]?.doubleValue ?? 0, height: box["Height"]?.doubleValue ?? 0
                )
            } ?? .zero
            surfaces.append(OnScreenSurface(owner: owner, level: level, bounds: bounds))
        }
        let showing = systemOverviewShowing(surfaces, screens: screens())
        guard showing != last, !stopped else {
            return
        }
        last = showing
        DispatchQueue.main.async { [onChange] in
            onChange(showing)
        }
    }
}
