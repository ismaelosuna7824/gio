import CoreGraphics
import Foundation
import GioCore

/// NA-03: the main-thread side of a close ghost: one tiny click-through
/// layer the size of the closed window (no backdrop), showing `image`, that
/// fades out while it shrinks by `shrink` over `duration` and then removes
/// itself. `removeGhost` takes it down at once (idempotent). The host
/// forwards both calls to the main thread; the session never waits for them.
public protocol CloseGhostPort: AnyObject, Sendable {
    func showGhost(token: Int, image: CGImage, frame: CGRect, duration: TimeInterval, shrink: CGFloat)
    func removeGhost(token: Int)
}

/// NA-03: shows the optional close ghost of windows about to be purged.
/// Opt-in (`[animations.window-close] ghost`), and only from a fresh cached
/// image (`closeGhostFrame`); never captures anything itself. Each ghost has
/// one watchdog removal after its fade; nothing runs at rest. Session queue
/// only. Logs carry numeric IDs, never titles.
public final class CloseGhostController: @unchecked Sendable {
    public struct Context {
        /// Ghost configured and the close animation active.
        public var isEnabled: () -> Bool
        public var isMinimized: (WindowID) -> Bool
        public var physicalFrame: (WindowID) -> CGRect?
        public var viewports: () -> [CGRect]
        /// The cached image, the frame it was taken at and when.
        public var cachedImage: (WindowID) -> (CGImage, CGRect, TimeInterval)?
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            isEnabled: @escaping () -> Bool, isMinimized: @escaping (WindowID) -> Bool,
            physicalFrame: @escaping (WindowID) -> CGRect?, viewports: @escaping () -> [CGRect],
            cachedImage: @escaping (WindowID) -> (CGImage, CGRect, TimeInterval)?,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.isEnabled = isEnabled
            self.isMinimized = isMinimized
            self.physicalFrame = physicalFrame
            self.viewports = viewports
            self.cachedImage = cachedImage
            self.log = log
            self.now = now
        }
    }

    /// An app quitting with many windows shows a few ghosts, not a wall.
    public static let maxGhosts = 4
    /// Slack after the fade before the watchdog removal.
    static let removalSlack: TimeInterval = 0.1

    private let context: Context
    private let port: CloseGhostPort
    private let scheduler: SessionScheduler
    private var live: Set<Int> = []
    private var token = 0

    public init(context: Context, port: CloseGhostPort, scheduler: SessionScheduler) {
        self.context = context
        self.port = port
        self.scheduler = scheduler
    }

    public var liveGhosts: Int { live.count }

    /// Called before the windows leave the registry and the image cache.
    public func windowsClosing(_ ids: [WindowID]) {
        guard context.isEnabled() else {
            return
        }
        let viewports = context.viewports()
        let now = context.now()
        for id in ids.sorted() where live.count < Self.maxGhosts {
            let cached = context.cachedImage(id)
            guard let frame = closeGhostFrame(
                enabled: true, isMinimized: context.isMinimized(id), physical: context.physicalFrame(id),
                cachedFrame: cached?.1, capturedAt: cached?.2, viewports: viewports, now: now
            ), let image = cached?.0 else {
                continue
            }
            token += 1
            let token = token
            live.insert(token)
            port.showGhost(
                token: token, image: image, frame: frame, duration: closeGhostDuration, shrink: closeGhostShrink
            )
            context.log(.debug, "close ghost id=\(id.pid):\(id.elementID)")
            scheduler.asyncAfter(closeGhostDuration + Self.removalSlack) { [weak self] in
                self?.remove(token)
            }
        }
    }

    /// Shutdown, restart: every ghost comes down now.
    public func removeAll() {
        for token in live.sorted() {
            port.removeGhost(token: token)
        }
        live = []
    }

    private func remove(_ token: Int) {
        guard live.remove(token) != nil else {
            return
        }
        port.removeGhost(token: token)
    }
}
