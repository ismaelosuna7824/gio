import Foundation
import GioCore
import GioMacOS

/// Config reload and live edits: the effective hotkey table (read by the
/// main-thread tap under its own lock), the config messages for the
/// Overview, the focus-follows-mouse tap restart decision, and the ordered
/// work after `session.config` changed. Everything except `currentDispatcher()`
/// and `applyConfigEdits(_:)` runs on the session queue.
public final class ConfigCoordinator: @unchecked Sendable {
    public struct Context {
        public var session: () -> CommandSession
        /// Re-reads the config into the session (`dispatch(.reload, ...)` live).
        public var reloadSession: () -> Void
        /// The config file's load messages (errors and warnings).
        public var loadMessages: () -> [String]
        /// Patches the config file; nothing is written when it is rejected.
        public var patchFile: ([ConfigEdit]) -> Result<PatchedConfig, ConfigErrors>
        /// The configured log level took effect (logger and actuator call counts).
        public var applyLogLevel: (LogLevel) -> Void
        /// Plans and gates that depend on config (inactive parking, ring gate).
        public var invalidateConfigCaches: () -> Void
        /// Hands the focus-follows-mouse flag to the pointer path (its own lock).
        public var setFocusFollowsMouse: (Bool) -> Void
        /// Whether the running tap observes mouse moves; nil without a tap.
        public var tapObservesMouseMoved: () -> Bool?
        /// Rebuilds the tap on the main thread (it re-checks there).
        public var requestTapRestart: () -> Void
        public var reapplyRules: () -> Void
        public var reflow: () -> Void
        public var publishSnapshot: () -> Void
        public var publishFocusRing: () -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            session: @escaping () -> CommandSession, reloadSession: @escaping () -> Void,
            loadMessages: @escaping () -> [String],
            patchFile: @escaping ([ConfigEdit]) -> Result<PatchedConfig, ConfigErrors>,
            applyLogLevel: @escaping (LogLevel) -> Void, invalidateConfigCaches: @escaping () -> Void,
            setFocusFollowsMouse: @escaping (Bool) -> Void, tapObservesMouseMoved: @escaping () -> Bool?,
            requestTapRestart: @escaping () -> Void, reapplyRules: @escaping () -> Void,
            reflow: @escaping () -> Void, publishSnapshot: @escaping () -> Void,
            publishFocusRing: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void
        ) {
            self.session = session
            self.reloadSession = reloadSession
            self.loadMessages = loadMessages
            self.patchFile = patchFile
            self.applyLogLevel = applyLogLevel
            self.invalidateConfigCaches = invalidateConfigCaches
            self.setFocusFollowsMouse = setFocusFollowsMouse
            self.tapObservesMouseMoved = tapObservesMouseMoved
            self.requestTapRestart = requestTapRestart
            self.reapplyRules = reapplyRules
            self.reflow = reflow
            self.publishSnapshot = publishSnapshot
            self.publishFocusRing = publishFocusRing
            self.log = log
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    /// Effective hotkey table (defaults + config). Read on the main thread
    /// by the tap, rebuilt on the session queue at start and on reload.
    private let dispatcherLock = NSLock()
    private var dispatcherTable = HotkeyDispatcher()
    /// Config load messages (errors and warnings) for the Overview; session queue.
    public private(set) var messages: [String] = []

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    /// Any thread: the current hotkey table.
    public func currentDispatcher() -> HotkeyDispatcher {
        dispatcherLock.lock()
        defer { dispatcherLock.unlock() }
        return dispatcherTable
    }

    /// Launch: the messages of the config the session started with.
    public func setMessages(_ messages: [String]) {
        self.messages = messages
    }

    /// Rebuild the hotkey table and the focus-follows-mouse flag from the
    /// session config; the tap only subscribes to pointer moves while
    /// focus-follows-mouse is on, so it is rebuilt when a reload flips that.
    public func refreshDispatcher() {
        let config = context.session().config
        let table = config.makeDispatcher()
        dispatcherLock.lock()
        dispatcherTable = table
        dispatcherLock.unlock()
        let wanted = config.behavior.focusFollowsMouse
        context.setFocusFollowsMouse(wanted)
        if let observing = context.tapObservesMouseMoved(),
           tapNeedsRestart(observingMouseMoved: observing, wanted: wanted)
        {
            context.requestTapRestart()
        }
    }

    /// Same effect as the IPC `reload` verb, driven by the app.
    public func reloadFromApp() {
        scheduler.async { [weak self] in
            guard let self else {
                return
            }
            context.reloadSession()
            applyReloadedConfig()
            context.log(.info, "config reloaded from the app")
        }
    }

    /// Patch config.toml from the app, then reload it exactly like the IPC
    /// `reload` verb. Nothing is reloaded when the edit is rejected. The file
    /// patch and validation need no session state, so they run on the caller
    /// (main) without waiting on the queue; only the live reload hops onto it.
    public func applyConfigEdits(_ edits: [ConfigEdit]) -> Result<PatchedConfig, ConfigErrors> {
        let result = context.patchFile(edits)
        if case .success = result {
            scheduler.async { [weak self] in
                guard let self else {
                    return
                }
                context.reloadSession()
                applyReloadedConfig()
                context.log(.info, "config edited from the app and reloaded")
            }
        }
        return result
    }

    /// After `session.config` changed: rebuild bindings and messages,
    /// re-evaluate rules, relayout. Session queue.
    public func applyReloadedConfig() {
        context.applyLogLevel(context.session().config.logging.level)
        context.invalidateConfigCaches()
        refreshDispatcher()
        messages = context.loadMessages()
        context.reapplyRules()
        context.reflow()
        context.publishSnapshot()
        context.publishFocusRing()
    }
}
