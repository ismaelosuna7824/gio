import Foundation
import GioCore

/// IPC requests on the session queue: dispatch the argv against the
/// session, then do what the command asks of the live session (reload the
/// config, focus intent + reflow, restart after the reply left) and push
/// the menu bar state. Session queue only (the server hops on with `sync`).
public final class IPCRouter: @unchecked Sendable {
    /// Delay before `gio restart` runs, so the reply reaches the client
    /// before the socket goes away.
    public static let restartDelay: TimeInterval = 0.3

    public struct Context {
        public var focusedWindow: () -> WindowID?
        /// `dispatchIPC(argv, session: &session, restartAvailable: true)` live.
        public var dispatch: ([String]) -> IPCResponse
        public var applyReloadedConfig: () -> Void
        /// Keyboard/IPC focus intent (`carries`, previous focus).
        public var requestFocusIntent: (Bool, WindowID?) -> Void
        public var reflow: () -> Void
        public var publishBar: () -> Void
        /// Runs `block` on the main thread after `delay` seconds.
        public var mainAfter: (TimeInterval, @escaping @Sendable () -> Void) -> Void
        /// Main thread: the app shuts the session down and relaunches itself.
        public var restart: () -> Void
        public var log: (LogLevel, String) -> Void

        public init(
            focusedWindow: @escaping () -> WindowID?, dispatch: @escaping ([String]) -> IPCResponse,
            applyReloadedConfig: @escaping () -> Void, requestFocusIntent: @escaping (Bool, WindowID?) -> Void,
            reflow: @escaping () -> Void, publishBar: @escaping () -> Void,
            mainAfter: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void,
            restart: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void
        ) {
            self.focusedWindow = focusedWindow
            self.dispatch = dispatch
            self.applyReloadedConfig = applyReloadedConfig
            self.requestFocusIntent = requestFocusIntent
            self.reflow = reflow
            self.publishBar = publishBar
            self.mainAfter = mainAfter
            self.restart = restart
            self.log = log
        }
    }

    private let context: Context

    public init(context: Context) {
        self.context = context
    }

    @discardableResult
    public func handle(_ argv: [String]) -> IPCResponse {
        let parsed = parseCLICommand(argv)
        let previousFocus = context.focusedWindow()
        let response = context.dispatch(argv)
        if case .success(let command) = parsed {
            if command.requestsSessionRestart {
                context.log(.info, "restart requested over IPC")
                // Let the reply reach the client before the socket goes away.
                context.mainAfter(Self.restartDelay) { [weak self] in
                    self?.context.restart()
                }
            }
            switch command {
            case .reload:
                context.applyReloadedConfig()
            case .focus, .move, .workspace:
                context.requestFocusIntent(command.carriesFocusIntent, previousFocus)
                context.reflow()
            default:
                break
            }
        }
        context.publishBar()
        return response
    }
}
